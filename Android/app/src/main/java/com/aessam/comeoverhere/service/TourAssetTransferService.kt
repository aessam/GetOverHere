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
import com.aessam.toursession.GuideAssetSchedule
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory

sealed class TourAssetTransferEvent {
    data class AuthenticationFailed(val message: String) : TourAssetTransferEvent()
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
    private val guideSchedule: GuideAssetSchedule = GuideAssetSchedule(),
    private val readSource: (File, Long, Int) -> ByteArray = { source, offset, count ->
        ByteArray(count).also { bytes -> RandomAccessFile(source, "r").use { file -> file.seek(offset); file.readFully(bytes) } }
    },
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
    private val lifecycleLock = Any()
    @Volatile private var transferGeneration = 0L
    @Volatile private var configuredSessionID: UUID? = null
    @Volatile private var priorityHashes: Pair<String?, String?> = null to null
    @Volatile private var guideDrainTask: ScheduledFuture<*>? = null
    private val pendingGuideEvents = Semaphore(90)
    internal val pendingGuideEventCount: Int get() = 90 - pendingGuideEvents.availablePermits()
    private val sourcesByHash = ConcurrentHashMap<String, GuideSource>()
    // Guest request scheduler (FND-9): ordered unique hashes waiting for a slot, hashes with an
    // outstanding request, failed full-transfer counts, and the per-hash inactivity deadline.
    private val pendingHashes = ConcurrentLinkedDeque<String>()
    private val inFlightHashes = ConcurrentHashMap.newKeySet<String>()
    private val transferAttempts = ConcurrentHashMap<String, Int>()
    private val inFlightDeadlines = ConcurrentHashMap<String, ScheduledFuture<*>>()
    private val mutableReadyFilesByAssetID = ConcurrentHashMap<String, File>()
    private val mutableConnectedParticipantIDs = ConcurrentHashMap.newKeySet<UUID>()
    private val memberGenerations = ConcurrentHashMap<UUID, UUID>()
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

    private var transportGeneration = 0L

    init {
        installTransportHandler(transportGeneration)
    }

    private fun installTransportHandler(transportRun: Long) {
        transport.setEventHandler handler@{ event ->
            val generation = synchronized(lifecycleLock) {
                if (transportRun != transportGeneration) return@handler
                transferGeneration
            }
            val bounded = role == Role.GUIDE && event is SessionAssetEvent.EnvelopeReceived
            if (bounded && event.envelope.payload.size > 8 * 1024) {
                report("Guide asset request/status payload is too large")
                return@handler
            }
            if (bounded && !pendingGuideEvents.tryAcquire()) {
                report("Guide asset event backlog is full; request rejected")
                return@handler
            }
            // Do not let a slow file read send to a member whose connection has already closed.
            val memberGeneration = synchronized(lifecycleLock) {
                if (generation != transferGeneration) null else when (event) {
                    is SessionAssetEvent.GuestJoined -> UUID.randomUUID().also {
                        mutableConnectedParticipantIDs.remove(event.participant.participantId)
                        memberGenerations[event.participant.participantId] = it
                    }
                    is SessionAssetEvent.GuestDisconnected -> {
                        mutableConnectedParticipantIDs.remove(event.participantID)
                        memberGenerations.remove(event.participantID)
                    }
                    is SessionAssetEvent.EnvelopeReceived -> memberGenerations[event.envelope.senderId]
                    else -> null
                }
            }
            worker.execute {
                try {
                    val memberStillCurrent = when (event) {
                        is SessionAssetEvent.GuestJoined -> memberGenerations[event.participant.participantId] == memberGeneration
                        is SessionAssetEvent.GuestDisconnected -> !memberGenerations.containsKey(event.participantID)
                        is SessionAssetEvent.EnvelopeReceived -> role != Role.GUIDE || memberGenerations[event.envelope.senderId] == memberGeneration
                        else -> true
                    }
                    if (generation == transferGeneration && memberStillCurrent) handle(event)
                }
                catch (error: Exception) { if (generation == transferGeneration) report(error) }
                finally { if (bounded) pendingGuideEvents.release() }
            }
        }
    }

    private fun beginTransferRun(installHandler: Boolean = true, preserveTransportRun: Boolean = false) = synchronized(lifecycleLock) {
        if (!preserveTransportRun) transportGeneration++
        transferGeneration++
        val generation = transferGeneration
        guideDrainTask?.cancel(false)
        guideDrainTask = null
        worker.execute {
            if (generation == transferGeneration) {
                try {
                    guideSchedule.reset()
                    guideSchedule.setPriority(priorityHashes.first, priorityHashes.second)
                    resetGuestTransferQueue()
                } catch (error: Exception) { report(error) }
            }
        }
        if (installHandler) installTransportHandler(transportGeneration)
    }

    /** Prioritizes queued work and yields background slots only after their outstanding chunk arrives. */
    fun prioritizeAssets(currentHash: String?, nextHash: String?) {
        priorityHashes = currentHash to nextHash
        val generation = transferGeneration
        worker.execute {
            if (generation != transferGeneration) return@execute
            try {
                guideSchedule.setPriority(currentHash, nextHash)
                prioritizePendingHashes()
                if (role == Role.GUEST) pumpRequests()
            } catch (error: Exception) { report(error) }
        }
    }

    private fun prioritizePendingHashes() {
        val (current, next) = priorityHashes
        val ordered = pendingHashes.toList().sortedBy { if (it == current) 0 else if (it == next) 1 else 2 }
        pendingHashes.clear()
        pendingHashes.addAll(ordered)
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
        configuredSessionID = sessionID
        beginTransferRun()
        transport.configureSession(sessionID, participantID, displayName, platform, credential)
    }

    fun configureGuideAuthentication(authentication: com.aessam.comeoverhere.core.SessionGuideAuthentication) =
        transport.configureGuideAuthentication(authentication)

    fun hostTourPack(manifest: TourPackManifestPayload, sourcesByAssetID: Map<String, File>) {
        val validated = validateSources(manifest, sourcesByAssetID)
        val isUpdatingActiveGuide = role == Role.GUIDE && transport.isActive
        beginTransferRun(installHandler = !isUpdatingActiveGuide, preserveTransportRun = isUpdatingActiveGuide)
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
            val generation = transferGeneration
            worker.execute { if (generation == transferGeneration) mutableConnectedParticipantIDs.forEach(guideSchedule::register) }
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
        beginTransferRun()
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
        beginTransferRun()
        role = Role.GUEST
        transport.hostIP = hostIP
        transport.startGuest()
    }

    fun setGuestSocketFactory(factory: SocketFactory?) {
        transport.setGuestSocketFactory(factory)
    }

    fun stop() {
        beginTransferRun(installHandler = false)
        transport.stop()
        role = null
        mutableConnectedParticipantIDs.clear()
        memberGenerations.clear()
        readyHashesByParticipant.clear()
        mutableReadyParticipantIDs.clear()
        publishReadiness()
    }

    fun clearSession() {
        stop()
        configuredSessionID = null
        transport.clearSession()
    }

    fun isParticipantReady(participantID: UUID): Boolean =
        mutableReadyParticipantIDs.contains(participantID)

    private fun handle(event: SessionAssetEvent) {
        when (event) {
            is SessionAssetEvent.GuestJoined -> {
                val current = manifest
                if (role == Role.GUIDE && current != null) {
                    try {
                        guideSchedule.remove(event.participant.participantId)
                        guideSchedule.register(event.participant.participantId)
                        mutableConnectedParticipantIDs += event.participant.participantId
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
                guideSchedule.remove(event.participantID)
                mutableConnectedParticipantIDs.remove(event.participantID)
                readyHashesByParticipant.remove(event.participantID)
                mutableReadyParticipantIDs.remove(event.participantID)
                publishReadiness()
            }
            is SessionAssetEvent.Failed -> report(event.message)
            is SessionAssetEvent.AuthenticationFailed -> eventHandler?.invoke(TourAssetTransferEvent.AuthenticationFailed(event.message))
            is SessionAssetEvent.CredentialRejected -> eventHandler?.invoke(TourAssetTransferEvent.AuthenticationFailed(event.message))
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
        val generation = transferGeneration
        try {
            require(envelope.sessionId == configuredSessionID) { "Asset message belongs to a different room" }
            when {
                role == Role.GUIDE && envelope.kind == SessionMessageKind.ASSET_REQUEST ->
                    handleGuideRequest(AssetRequestPayload.decode(envelope.payload), envelope.senderId)
                role == Role.GUIDE && envelope.kind == SessionMessageKind.ASSET_STATUS ->
                    handleGuideStatus(AssetStatusPayload.decode(envelope.payload), envelope.senderId)
                role == Role.GUEST && envelope.kind == SessionMessageKind.TOUR_PACK_MANIFEST ->
                    handleGuestManifest(TourPackManifestPayload.decode(envelope.payload), generation)
                role == Role.GUEST && envelope.kind == SessionMessageKind.ASSET_CHUNK ->
                    handleGuestChunk(AssetChunkPayload.decode(envelope.payload), generation)
                else -> throw TourAssetTransferException(
                    "Unexpected asset-channel message ${envelope.kind.wireName}",
                )
            }
        } catch (error: Exception) {
            if (generation != transferGeneration) return
            report(error)
            if (role == Role.GUEST) {
                hashIfAvailable(envelope)?.let { hash ->
                    sendStatus(hash, AssetTransferStatus.FAILED, 0, error.message ?: error.javaClass.simpleName, generation)
                    finishTransfer(hash, generation)
                }
            }
        }
    }

    private fun handleGuideRequest(request: AssetRequestPayload, participantID: UUID) {
        require(participantID in mutableConnectedParticipantIDs) { "Asset request is not from a connected member" }
        val source = sourcesByHash[request.sha256]
            ?: throw TourAssetTransferException("Unknown requested asset hash ${request.sha256}")
        val length = source.descriptor.byteLength
        if (request.offset !in 0 until length) {
            throw TourAssetTransferException(
                "Invalid request offset ${request.offset} for ${request.sha256} with length $length",
            )
        }
        guideSchedule.enqueue(participantID, request.sha256, request.offset, length - request.offset)
        scheduleGuideChunk()
    }

    private fun scheduleGuideChunk() {
        if (role != Role.GUIDE || guideDrainTask != null) return
        val delay = guideSchedule.delayUntilNextReservation(monotonicMilliseconds()) ?: return
        val generation = transferGeneration
        guideDrainTask = worker.schedule({
            if (generation != transferGeneration || role != Role.GUIDE) return@schedule
            guideDrainTask = null
            val reservation = guideSchedule.dequeue(monotonicMilliseconds())
            if (reservation != null) {
                try {
                    val source = sourcesByHash[reservation.sha256]
                    val memberGeneration = memberGenerations[reservation.memberId]
                    if (source != null && reservation.memberId in mutableConnectedParticipantIDs && generation == transferGeneration) {
                        require(reservation.byteCount <= CHUNK_SIZE) { "Scheduled asset chunk exceeds the signed-frame bound" }
                        val bytes = readSource(source.file, reservation.offset, reservation.byteCount)
                        require(bytes.size == reservation.byteCount) { "Asset source returned an incomplete chunk" }
                        synchronized(lifecycleLock) {
                            if (generation == transferGeneration && role == Role.GUIDE &&
                                reservation.memberId in mutableConnectedParticipantIDs && memberGenerations[reservation.memberId] == memberGeneration &&
                                sourcesByHash[reservation.sha256] === source) {
                                val chunk = AssetChunkPayload(reservation.sha256, reservation.offset, source.descriptor.byteLength, bytes)
                                transport.send(SessionMessageKind.ASSET_CHUNK, chunk.encode(), reservation.memberId)
                            }
                        }
                    }
                } catch (error: Exception) {
                    if (generation == transferGeneration) report(error)
                } finally { guideSchedule.complete(reservation.id) }
            }
            if (generation == transferGeneration) scheduleGuideChunk()
        }, delay, TimeUnit.MILLISECONDS)
    }

    private fun monotonicMilliseconds(): Long = System.nanoTime() / 1_000_000

    private fun handleGuideStatus(status: AssetStatusPayload, participantID: UUID) {
        require(participantID in mutableConnectedParticipantIDs) { "Asset status is not from a connected member" }
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

    private fun handleGuestManifest(manifest: TourPackManifestPayload, generation: Long) {
        val current = this.manifest
        if (
            current != null &&
            current.packID == manifest.packID &&
            current.manifestVersion > manifest.manifestVersion
        ) return

        this.manifest = manifest
        eventHandler?.invoke(TourAssetTransferEvent.ManifestReceived(manifest))
        if (generation != transferGeneration) return

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
                if (generation != transferGeneration) return
                if (ready != null) {
                    markReady(descriptor.sha256, ready, generation)
                    sendStatus(descriptor.sha256, AssetTransferStatus.READY, descriptor.byteLength, "", generation)
                } else {
                    pendingHashes.addLast(descriptor.sha256)
                }
            } catch (error: Exception) {
                if (generation != transferGeneration) return
                report(error)
                sendStatus(descriptor.sha256, AssetTransferStatus.FAILED, 0, error.message ?: error.javaClass.simpleName, generation)
            }
        }
        prioritizePendingHashes()
        pumpRequests(generation)
    }

    /** Starts requests until [MAX_IN_FLIGHT_REQUESTS] are outstanding; the slot is reserved before the cache call. */
    private fun pumpRequests(generation: Long = transferGeneration) {
        while (inFlightHashes.size < MAX_IN_FLIGHT_REQUESTS) {
            if (generation != transferGeneration || role != Role.GUEST) return
            val hash = pendingHashes.pollFirst() ?: return
            val descriptor = manifest?.assets?.firstOrNull { it.sha256 == hash }
            if (descriptor == null) {
                System.err.println("Asset transfer: dropping pending hash $hash that is no longer in the manifest")
                continue
            }
            inFlightHashes += hash
            try {
                val offset = cache.resumeOffset(hash, descriptor.byteLength)
                if (generation != transferGeneration) return
                sendRequest(hash, offset, generation)
            } catch (error: Exception) {
                if (generation != transferGeneration) return
                inFlightHashes.remove(hash)
                inFlightDeadlines.remove(hash)?.cancel(false)
                report(error)
                sendStatus(hash, AssetTransferStatus.FAILED, 0, error.message ?: error.javaClass.simpleName, generation)
            }
        }
    }

    private fun finishTransfer(hash: String, generation: Long = transferGeneration) {
        if (generation != transferGeneration) return
        inFlightHashes.remove(hash)
        transferAttempts.remove(hash)
        inFlightDeadlines.remove(hash)?.cancel(false)
        pumpRequests(generation)
    }

    private fun resetGuestTransferQueue() {
        pendingHashes.clear()
        inFlightHashes.clear()
        transferAttempts.clear()
        inFlightDeadlines.values.forEach { it.cancel(false) }
        inFlightDeadlines.clear()
    }

    /** Re-armed on every request for [hash]; cancelled when the transfer finishes or the queue resets. */
    private fun armInFlightDeadline(hash: String, generation: Long) {
        inFlightDeadlines.remove(hash)?.cancel(false)
        inFlightDeadlines[hash] = worker.schedule(
            { if (generation == transferGeneration) expireInFlightRequest(hash, generation) },
            inFlightDeadlineMillis,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun expireInFlightRequest(hash: String, generation: Long) {
        if (generation != transferGeneration || hash !in inFlightHashes) return
        inFlightDeadlines.remove(hash)
        val detail = "no chunk received within ${describeSeconds(inFlightDeadlineMillis)}"
        val assetID = manifest?.assets?.firstOrNull { it.sha256 == hash }?.assetID ?: hash
        report("Asset $assetID: $detail")
        sendStatus(hash, AssetTransferStatus.FAILED, 0, detail, generation)
        finishTransfer(hash, generation)
    }

    private fun handleGuestChunk(chunk: AssetChunkPayload, generation: Long) {
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
            if (generation != transferGeneration) return
            // The cache already deleted the partial, so a retry restarts at offset 0.
            val failed = transferAttempts.merge(chunk.sha256, 1, Int::plus) ?: 1
            if (failed >= MAX_TRANSFER_ATTEMPTS) throw error
            System.err.println(
                "Asset transfer: checksum mismatch for ${chunk.sha256} (attempt $failed of $MAX_TRANSFER_ATTEMPTS); " +
                    "re-requesting from offset 0",
            )
            sendRequest(chunk.sha256, 0, generation)
            return
        }
        if (generation != transferGeneration) return
        when (result) {
            is AssetCacheIngestResult.Partial -> {
                if (!yieldBackgroundTransferToPriority(chunk.sha256, generation)) sendRequest(chunk.sha256, result.nextOffset, generation)
            }
            is AssetCacheIngestResult.Ready -> {
                markReady(chunk.sha256, result.file, generation)
                sendStatus(chunk.sha256, AssetTransferStatus.READY, chunk.totalLength, "", generation)
                finishTransfer(chunk.sha256, generation)
            }
        }
    }

    /** The previous request has been ingested. Yielding here never cancels or duplicates a chunk. */
    private fun yieldBackgroundTransferToPriority(hash: String, generation: Long): Boolean {
        if (generation != transferGeneration) return false
        val priority = listOfNotNull(priorityHashes.first, priorityHashes.second).toSet()
        if (hash in priority || pendingHashes.none { it in priority }) return false
        inFlightHashes.remove(hash)
        inFlightDeadlines.remove(hash)?.cancel(false)
        if (hash !in pendingHashes) pendingHashes.addLast(hash)
        prioritizePendingHashes()
        pumpRequests(generation)
        return true
    }

    private fun sendRequest(hash: String, offset: Long, generation: Long) = synchronized(lifecycleLock) {
        if (generation != transferGeneration || role != Role.GUEST) return@synchronized
        transport.send(
            SessionMessageKind.ASSET_REQUEST,
            AssetRequestPayload(hash, offset).encode(),
            null,
        )
        armInFlightDeadline(hash, generation)
    }

    private fun sendStatus(
        hash: String,
        status: AssetTransferStatus,
        byteLength: Long,
        detail: String,
        generation: Long,
    ) = synchronized(lifecycleLock) {
        if (generation != transferGeneration || role != Role.GUEST) return@synchronized
        try {
            val payload = AssetStatusPayload(hash, status, byteLength, detail.take(1024))
            transport.send(SessionMessageKind.ASSET_STATUS, payload.encode(), null)
        } catch (error: Exception) {
            report(error)
        }
    }

    private fun markReady(hash: String, file: File, generation: Long) = synchronized(lifecycleLock) {
        if (generation != transferGeneration || role != Role.GUEST) return@synchronized
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
        const val CHUNK_SIZE = 60 * 1024
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
