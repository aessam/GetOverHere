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
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
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
) {
    private enum class Role { GUIDE, GUEST }

    private data class GuideSource(
        val descriptor: TourAssetDescriptor,
        val file: File,
    )

    private val worker = Executors.newSingleThreadExecutor { body ->
        Thread(body, "tour-asset-transfer").apply { isDaemon = true }
    }
    private val sourcesByHash = ConcurrentHashMap<String, GuideSource>()
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
            is SessionAssetEvent.VersionMismatch -> report(
                "Tour protocol version mismatch (remote ${event.remoteMajor}, local ${event.localMajor}). " +
                    "Update the older app.",
            )
            SessionAssetEvent.Connected,
            SessionAssetEvent.Disconnected,
            -> Unit
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
        val requestedHashes = mutableSetOf<String>()
        manifest.assets.forEach { descriptor ->
            val ready = cache.readyFile(descriptor.sha256, descriptor.byteLength)
            if (ready != null) {
                markReady(descriptor.sha256, ready)
                if (requestedHashes.add(descriptor.sha256)) {
                    sendStatus(
                        descriptor.sha256,
                        AssetTransferStatus.READY,
                        descriptor.byteLength,
                        "",
                    )
                }
            } else if (requestedHashes.add(descriptor.sha256)) {
                sendRequest(
                    descriptor.sha256,
                    cache.resumeOffset(descriptor.sha256, descriptor.byteLength),
                )
            }
        }
    }

    private fun handleGuestChunk(chunk: AssetChunkPayload) {
        val descriptor = manifest?.assets?.firstOrNull { it.sha256 == chunk.sha256 }
            ?: throw TourAssetTransferException("Unknown asset hash ${chunk.sha256}")
        if (chunk.totalLength != descriptor.byteLength) {
            throw TourAssetTransferException(
                "Chunk length mismatch for ${chunk.sha256}: expected ${descriptor.byteLength}, got ${chunk.totalLength}",
            )
        }
        when (val result = cache.ingest(chunk)) {
            is AssetCacheIngestResult.Partial -> sendRequest(chunk.sha256, result.nextOffset)
            is AssetCacheIngestResult.Ready -> {
                markReady(chunk.sha256, result.file)
                sendStatus(chunk.sha256, AssetTransferStatus.READY, chunk.totalLength, "")
            }
        }
    }

    private fun sendRequest(hash: String, offset: Long) {
        transport.send(
            SessionMessageKind.ASSET_REQUEST,
            AssetRequestPayload(hash, offset).encode(),
            null,
        )
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

    private companion object {
        const val CHUNK_SIZE = 65_536
    }
}
