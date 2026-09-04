package com.aessam.comeoverhere.service

import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionAssetTransport
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.AssetRequestPayload
import com.aessam.toursession.AssetStatusPayload
import com.aessam.toursession.AssetTransferStatus
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourPackManifestPayload
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory

sealed class TourAssetTransferEvent {
    data class ManifestReceived(val manifest: TourPackManifestPayload) : TourAssetTransferEvent()
    data class AssetReady(val assetID: String, val file: File) : TourAssetTransferEvent()
    data class ParticipantReady(val participantID: UUID) : TourAssetTransferEvent()
    data class ParticipantReadinessChanged(val readyCount: Int) : TourAssetTransferEvent()
    data class Failed(val message: String) : TourAssetTransferEvent()
}

class TourAssetTransferException(message: String) : IllegalArgumentException(message)

class TourAssetTransferService(
    private val transport: SessionAssetTransport,
    private val cache: TourAssetCache,
    private val inFlightDeadlineMillis: Long = IN_FLIGHT_DEADLINE_MILLIS,
) {
    private enum class Role { GUIDE, GUEST }

    private data class GuideSource(
        val descriptor: TourAssetDescriptor,
        val file: File,
    )

    /** Single worker: every event, the request scheduler, and the inactivity deadlines run on it in FIFO order. */
    private val worker = Executors.newSingleThreadScheduledExecutor { body ->
        Thread(body, "tour-asset-transfer").apply { isDaemon = true }
    }
    private val sourcesByHash = ConcurrentHashMap<String, GuideSource>()
    // Guest request scheduler (FND-9): ordered unique hashes waiting for a slot, hashes with an
    // outstanding request, failed full-transfer counts, and the per-hash inactivity deadline.
    private val pendingHashes = ConcurrentLinkedDeque<String>()
    private val inFlightHashes = ConcurrentHashMap.newKeySet<String>()
    private val transferAttempts = ConcurrentHashMap<String, Int>()
    private val inFlightDeadlines = ConcurrentHashMap<String, ScheduledFuture<*>>()
    private val mutableReadyFilesByAssetID = ConcurrentHashMap<String, File>()
    private val mutableConnectedParticipantIDs = ConcurrentHashMap.newKeySet<UUID>()
    private val readyHashesByParticipant = ConcurrentHashMap<UUID, MutableSet<String>>()
    private val mutableReadyParticipantIDs = ConcurrentHashMap.newKeySet<UUID>()

    @Volatile private var role: Role? = null
    @Volatile private var eventHandler: ((TourAssetTransferEvent) -> Unit)? = null
    @Volatile var manifest: TourPackManifestPayload? = null
        private set
    @Volatile var lastError: String? = null
        private set

    val readyFilesByAssetID: Map<String, File> get() = mutableReadyFilesByAssetID.toMap()
    val connectedParticipantIDs: Set<UUID> get() = mutableConnectedParticipantIDs.toSet()
    val readyParticipantIDs: Set<UUID> get() = mutableReadyParticipantIDs.toSet()

    init {
        transport.setEventHandler { event -> worker.execute { handle(event) } }
    }

    fun setEventHandler(handler: ((TourAssetTransferEvent) -> Unit)?) {
        eventHandler = handler
    }

    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {
        transport.configureSession(sessionID, participantID, displayName, platform, credential)
    }

    fun hostTourPack(manifest: TourPackManifestPayload, sourcesByAssetID: Map<String, File>) {
        val validated = validateSources(manifest, sourcesByAssetID)
        val isUpdatingActiveGuide = role == Role.GUIDE && transport.isActive
        role = Role.GUIDE
        this.manifest = manifest
        sourcesByHash.clear()
        sourcesByHash.putAll(validated)
        readyHashesByParticipant.clear()
        mutableReadyParticipantIDs.clear()
        if (manifest.assets.isEmpty()) {
            mutableReadyParticipantIDs += mutableConnectedParticipantIDs
        }
        publishReadiness()
        if (isUpdatingActiveGuide) {
            transport.send(SessionMessageKind.TOUR_PACK_MANIFEST, manifest.encode(), null)
        } else {
            mutableConnectedParticipantIDs.clear()
            transport.startGuide()
        }
    }

    fun startGuideWithEmptyTourPack(manifest: TourPackManifestPayload) {
        if (manifest.assets.isNotEmpty()) {
            throw TourAssetTransferException("startGuideWithEmptyTourPack requires an empty manifest")
        }
        role = Role.GUIDE
        this.manifest = manifest
        sourcesByHash.clear()
        readyHashesByParticipant.clear()
        mutableReadyParticipantIDs.clear()
        mutableConnectedParticipantIDs.clear()
        publishReadiness()
        transport.startGuide()
    }

    fun joinTour(hostIP: String) {
        role = Role.GUEST
        transport.hostIP = hostIP
        transport.startGuest()
    }

    fun setGuestSocketFactory(factory: SocketFactory?) {
        transport.setGuestSocketFactory(factory)
    }

    fun stop() {
        transport.stop()
        role = null
        mutableConnectedParticipantIDs.clear()
        readyHashesByParticipant.clear()
        mutableReadyParticipantIDs.clear()
        publishReadiness()
        // On the worker so FIFO order puts the reset after any handler already running and before
        // every event of the next run; a synchronous clear could be overtaken by an in-flight manifest.
        worker.execute { resetGuestTransferQueue() }
    }

    fun clearSession() {
        stop()
        transport.clearSession()
    }

    fun isParticipantReady(participantID: UUID): Boolean =
        mutableReadyParticipantIDs.contains(participantID)

    private fun handle(event: SessionAssetEvent) {
        when (event) {
            is SessionAssetEvent.GuestJoined -> {
                val current = manifest
                if (role == Role.GUIDE && current != null) {
                    mutableConnectedParticipantIDs += event.participant.participantId
                    try {
                        transport.send(
                            SessionMessageKind.TOUR_PACK_MANIFEST,
                            current.encode(),
                            event.participant.participantId,
                        )
                        if (current.assets.isEmpty()) {
                            mutableReadyParticipantIDs += event.participant.participantId
                            publishReadiness()
                        }
                    } catch (error: Exception) {
                        report(error)
                    }
                }
            }
            is SessionAssetEvent.EnvelopeReceived -> handle(event.envelope)
            is SessionAssetEvent.GuestDisconnected -> {
                mutableConnectedParticipantIDs.remove(event.participantID)
                readyHashesByParticipant.remove(event.participantID)
                mutableReadyParticipantIDs.remove(event.participantID)
                publishReadiness()
            }
            is SessionAssetEvent.Failed -> report(event.message)
            is SessionAssetEvent.CredentialRejected -> report(event.message)
            is SessionAssetEvent.VersionMismatch -> report(
                "Tour protocol version mismatch (remote ${event.remoteMajor}, local ${event.localMajor}). " +
                    "Update the older app.",
            )
            SessionAssetEvent.Connected -> Unit
            // The guide re-sends the manifest on rejoin; the guest must re-request from a clean queue.
            SessionAssetEvent.Disconnected -> resetGuestTransferQueue()
        }
    }

    private fun handle(envelope: SessionEnvelope) {
        try {
            when {
                role == Role.GUIDE && envelope.kind == SessionMessageKind.ASSET_REQUEST ->
                    handleGuideRequest(AssetRequestPayload.decode(envelope.payload), envelope.senderId)
                role == Role.GUIDE && envelope.kind == SessionMessageKind.ASSET_STATUS ->
                    handleGuideStatus(AssetStatusPayload.decode(envelope.payload), envelope.senderId)
                role == Role.GUEST && envelope.kind == SessionMessageKind.TOUR_PACK_MANIFEST ->
                    handleGuestManifest(TourPackManifestPayload.decode(envelope.payload))
                role == Role.GUEST && envelope.kind == SessionMessageKind.ASSET_CHUNK ->
                    handleGuestChunk(AssetChunkPayload.decode(envelope.payload))
                else -> throw TourAssetTransferException(
                    "Unexpected asset-channel message ${envelope.kind.wireName}",
                )
            }
        } catch (error: Exception) {
            report(error)
            if (role == Role.GUEST) {
                hashIfAvailable(envelope)?.let { hash ->
                    sendStatus(hash, AssetTransferStatus.FAILED, 0, error.message ?: error.javaClass.simpleName)
                    finishTransfer(hash)
                }
            }
        }
    }

    private fun handleGuideRequest(request: AssetRequestPayload, participantID: UUID) {
        val source = sourcesByHash[request.sha256]
            ?: throw TourAssetTransferException("Unknown requested asset hash ${request.sha256}")
        val length = source.descriptor.byteLength
        if (request.offset !in 0 until length) {
            throw TourAssetTransferException(
                "Invalid request offset ${request.offset} for ${request.sha256} with length $length",
            )
        }
        val count = minOf(CHUNK_SIZE.toLong(), length - request.offset).toInt()
        val bytes = ByteArray(count)
        RandomAccessFile(source.file, "r").use { file ->
            file.seek(request.offset)
            file.readFully(bytes)
        }
        val chunk = AssetChunkPayload(request.sha256, request.offset, length, bytes)
        transport.send(SessionMessageKind.ASSET_CHUNK, chunk.encode(), participantID)
    }

    private fun handleGuideStatus(status: AssetStatusPayload, participantID: UUID) {
        val descriptor = manifest?.assets?.firstOrNull { it.sha256 == status.sha256 }
            ?: throw TourAssetTransferException("Unknown asset hash ${status.sha256}")
        if (status.status != AssetTransferStatus.READY) {
            report("Guest asset failure for ${status.sha256}: ${status.detail}")
            return
        }
        if (status.byteLength != descriptor.byteLength) {
            throw TourAssetTransferException(
                "Asset length mismatch for ${status.sha256}: expected ${descriptor.byteLength}, got ${status.byteLength}",
            )
        }
        val readyHashes = readyHashesByParticipant.computeIfAbsent(participantID) {
            ConcurrentHashMap.newKeySet()
        }
        readyHashes += status.sha256
        val expected = manifest?.assets?.map { it.sha256 }?.toSet().orEmpty()
        if (readyHashes.containsAll(expected)) {
            mutableReadyParticipantIDs += participantID
            eventHandler?.invoke(TourAssetTransferEvent.ParticipantReady(participantID))
            publishReadiness()
        }
    }

    private fun handleGuestManifest(manifest: TourPackManifestPayload) {
        val current = this.manifest
        if (
            current != null &&
            current.packID == manifest.packID &&
            current.manifestVersion > manifest.manifestVersion
        ) return

        this.manifest = manifest
        eventHandler?.invoke(TourAssetTransferEvent.ManifestReceived(manifest))

        // Hashes still in flight from the previous manifest keep their slot and are not re-requested,
        // which avoids a duplicate-chunk offset mismatch; everything else is rebuilt from this manifest.
        val wanted = manifest.assets.map { it.sha256 }.toSet()
        pendingHashes.clear()
        inFlightHashes.filter { it !in wanted }.forEach { inFlightDeadlines.remove(it)?.cancel(false) }
        inFlightHashes.retainAll(wanted)
        transferAttempts.keys.retainAll(wanted)

        val seen = mutableSetOf<String>()
        manifest.assets.forEach { descriptor ->
            if (!seen.add(descriptor.sha256) || descriptor.sha256 in inFlightHashes) return@forEach
            // Every asset is isolated: one cache failure reports FAILED for that asset and the loop goes on.
            try {
                val ready = cache.readyFile(descriptor.sha256, descriptor.byteLength)
                if (ready != null) {
                    markReady(descriptor.sha256, ready)
                    sendStatus(descriptor.sha256, AssetTransferStatus.READY, descriptor.byteLength, "")
                } else {
                    pendingHashes.addLast(descriptor.sha256)
                }
            } catch (error: Exception) {
                report(error)
                sendStatus(descriptor.sha256, AssetTransferStatus.FAILED, 0, error.message ?: error.javaClass.simpleName)
            }
        }
        pumpRequests()
    }

    /** Starts requests until [MAX_IN_FLIGHT_REQUESTS] are outstanding; the slot is reserved before the cache call. */
    private fun pumpRequests() {
        while (inFlightHashes.size < MAX_IN_FLIGHT_REQUESTS) {
            val hash = pendingHashes.pollFirst() ?: return
            val descriptor = manifest?.assets?.firstOrNull { it.sha256 == hash }
            if (descriptor == null) {
                System.err.println("Asset transfer: dropping pending hash $hash that is no longer in the manifest")
                continue
            }
            inFlightHashes += hash
            try {
                sendRequest(hash, cache.resumeOffset(hash, descriptor.byteLength))
            } catch (error: Exception) {
                inFlightHashes.remove(hash)
                inFlightDeadlines.remove(hash)?.cancel(false)
                report(error)
                sendStatus(hash, AssetTransferStatus.FAILED, 0, error.message ?: error.javaClass.simpleName)
            }
        }
    }

    private fun finishTransfer(hash: String) {
        inFlightHashes.remove(hash)
        transferAttempts.remove(hash)
        inFlightDeadlines.remove(hash)?.cancel(false)
        pumpRequests()
    }

    private fun resetGuestTransferQueue() {
        pendingHashes.clear()
        inFlightHashes.clear()
        transferAttempts.clear()
        inFlightDeadlines.values.forEach { it.cancel(false) }
        inFlightDeadlines.clear()
    }

    /** Re-armed on every request for [hash]; cancelled when the transfer finishes or the queue resets. */
    private fun armInFlightDeadline(hash: String) {
        inFlightDeadlines.remove(hash)?.cancel(false)
        inFlightDeadlines[hash] = worker.schedule(
            { expireInFlightRequest(hash) },
            inFlightDeadlineMillis,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun expireInFlightRequest(hash: String) {
        if (hash !in inFlightHashes) return
        inFlightDeadlines.remove(hash)
        val detail = "no chunk received within ${describeSeconds(inFlightDeadlineMillis)}"
        val assetID = manifest?.assets?.firstOrNull { it.sha256 == hash }?.assetID ?: hash
        report("Asset $assetID: $detail")
        sendStatus(hash, AssetTransferStatus.FAILED, 0, detail)
        finishTransfer(hash)
    }

    private fun handleGuestChunk(chunk: AssetChunkPayload) {
        val descriptor = manifest?.assets?.firstOrNull { it.sha256 == chunk.sha256 }
            ?: throw TourAssetTransferException("Unknown asset hash ${chunk.sha256}")
        if (chunk.totalLength != descriptor.byteLength) {
            throw TourAssetTransferException(
                "Chunk length mismatch for ${chunk.sha256}: expected ${descriptor.byteLength}, got ${chunk.totalLength}",
            )
        }
        // Every chunk follows a request and every request reserves a slot, so the only chunk that
        // arrives without one is a late answer after the inactivity deadline already reported FAILED.
        if (chunk.sha256 !in inFlightHashes) {
            System.err.println("Asset transfer: ignoring chunk for ${chunk.sha256} that is no longer in flight")
            return
        }
        val result = try {
            cache.ingest(chunk)
        } catch (error: AssetChecksumMismatchException) {
            // The cache already deleted the partial, so a retry restarts at offset 0.
            val failed = transferAttempts.merge(chunk.sha256, 1, Int::plus) ?: 1
            if (failed >= MAX_TRANSFER_ATTEMPTS) throw error
            System.err.println(
                "Asset transfer: checksum mismatch for ${chunk.sha256} (attempt $failed of $MAX_TRANSFER_ATTEMPTS); " +
                    "re-requesting from offset 0",
            )
            sendRequest(chunk.sha256, 0)
            return
        }
        when (result) {
            is AssetCacheIngestResult.Partial -> sendRequest(chunk.sha256, result.nextOffset)
            is AssetCacheIngestResult.Ready -> {
                markReady(chunk.sha256, result.file)
                sendStatus(chunk.sha256, AssetTransferStatus.READY, chunk.totalLength, "")
                finishTransfer(chunk.sha256)
            }
        }
    }

    private fun sendRequest(hash: String, offset: Long) {
        transport.send(
            SessionMessageKind.ASSET_REQUEST,
            AssetRequestPayload(hash, offset).encode(),
            null,
        )
        armInFlightDeadline(hash)
    }

    private fun sendStatus(
        hash: String,
        status: AssetTransferStatus,
        byteLength: Long,
        detail: String,
    ) {
        try {
            val payload = AssetStatusPayload(hash, status, byteLength, detail.take(1024))
            transport.send(SessionMessageKind.ASSET_STATUS, payload.encode(), null)
        } catch (error: Exception) {
            report(error)
        }
    }

    private fun markReady(hash: String, file: File) {
        manifest?.assets?.filter { it.sha256 == hash }?.forEach { descriptor ->
            val wasMissing = mutableReadyFilesByAssetID.put(descriptor.assetID, file) == null
            if (wasMissing) {
                eventHandler?.invoke(TourAssetTransferEvent.AssetReady(descriptor.assetID, file))
            }
        }
    }

    private fun publishReadiness() {
        eventHandler?.invoke(TourAssetTransferEvent.ParticipantReadinessChanged(mutableReadyParticipantIDs.size))
    }

    private fun hashIfAvailable(envelope: SessionEnvelope): String? {
        if (envelope.kind != SessionMessageKind.ASSET_CHUNK) return null
        return try {
            AssetChunkPayload.decode(envelope.payload).sha256
        } catch (error: Exception) {
            System.err.println("Asset transfer: could not recover failed chunk hash (${error.javaClass.simpleName})")
            null
        }
    }

    private fun report(error: Exception) {
        report(error.message ?: error.javaClass.simpleName)
    }

    private fun report(message: String) {
        lastError = message
        eventHandler?.invoke(TourAssetTransferEvent.Failed(message))
    }

    private fun validateSources(
        manifest: TourPackManifestPayload,
        sourcesByAssetID: Map<String, File>,
    ): Map<String, GuideSource> {
        val result = mutableMapOf<String, GuideSource>()
        manifest.assets.forEach { descriptor ->
            val file = sourcesByAssetID[descriptor.assetID]
                ?: throw TourAssetTransferException("Source is missing for asset ${descriptor.assetID}")
            if (!file.isFile) {
                throw TourAssetTransferException("Source is not a file for asset ${descriptor.assetID}")
            }
            if (file.length() != descriptor.byteLength) {
                throw TourAssetTransferException(
                    "Source length mismatch for ${descriptor.assetID}: expected ${descriptor.byteLength}, got ${file.length()}",
                )
            }
            val actualHash = sha256(file)
            if (actualHash != descriptor.sha256) {
                throw TourAssetTransferException(
                    "Source checksum mismatch for ${descriptor.assetID}: expected ${descriptor.sha256}, got $actualHash",
                )
            }
            result[descriptor.sha256] = GuideSource(descriptor, file)
        }
        return result
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(1_048_576)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        const val CHUNK_SIZE = 65_536
        /**
         * The asset lane's per-peer writer holds 8 frames and disconnects on overflow
         * (`LocalSessionControlTransport`, ADR-039); two in-flight assets keep at most two 64 KiB
         * chunks queued per guest.
         */
        const val MAX_IN_FLIGHT_REQUESTS = 2
        /** A checksum-mismatched asset is re-requested once from offset 0, then reported FAILED. */
        const val MAX_TRANSFER_ATTEMPTS = 2
        /**
         * An in-flight request with no chunk for this long is reported FAILED and releases its slot
         * (DSCN-16); the guide has no failure frame for an unanswerable request.
         */
        const val IN_FLIGHT_DEADLINE_MILLIS = 15_000L

        private fun describeSeconds(millis: Long): String =
            if (millis % 1_000L == 0L) "${millis / 1_000L} s" else String.format(Locale.ROOT, "%.1f s", millis / 1_000.0)
    }
}
