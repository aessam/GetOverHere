package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.service.AssetCacheException
import com.aessam.comeoverhere.service.AssetCacheIngestResult
import com.aessam.comeoverhere.service.AssetChecksumMismatchException
import com.aessam.comeoverhere.service.TourAssetCache
import com.aessam.comeoverhere.service.TourAssetTransferEvent
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Blocking cache hooks exercise the production service across a synchronous room replacement.
 * A later transport event on its single worker is the completion barrier, not an arbitrary sleep.
 */
class GuestAssetGenerationTest {
    @Test(timeout = 15_000) fun staleReadyCacheResultCannotMarkOrSendForReplacementRoom() =
        checkBothTransitions(Operation.READY_FILE)

    @Test(timeout = 15_000) fun staleResumeOffsetCannotRequestFromReplacementRoom() =
        checkBothTransitions(Operation.RESUME_OFFSET)

    @Test(timeout = 15_000) fun stalePartialIngestCannotRequestAnotherOldChunk() =
        checkBothTransitions(Operation.INGEST_PARTIAL)

    @Test(timeout = 15_000) fun staleCompletedIngestCannotMarkOrSendReadiness() =
        checkBothTransitions(Operation.INGEST_READY)

    @Test(timeout = 15_000) fun staleChecksumFailureCannotRestartTransferInReplacementRoom() =
        checkBothTransitions(Operation.INGEST_CHECKSUM_FAILURE)

    @Test(timeout = 15_000) fun staleCacheFailureCannotSendFailureOrPumpOldWork() =
        checkBothTransitions(Operation.INGEST_FAILURE)

    private enum class Operation { READY_FILE, RESUME_OFFSET, INGEST_PARTIAL, INGEST_READY, INGEST_CHECKSUM_FAILURE, INGEST_FAILURE }

    private fun checkBothTransitions(operation: Operation) {
        for (stopFirst in listOf(false, true)) {
            val fixture = Fixture(operation)
            try {
                fixture.beginBlockedOperation()
                assertTrue("Cache operation never started", fixture.cache.entered.await(4, TimeUnit.SECONDS))
                val messagesBefore = fixture.transport.sent.size
                if (stopFirst) fixture.service.stop()
                fixture.configureNewRoom()
                fixture.cache.release.countDown()
                fixture.awaitWorkerBarrier()
                assertEquals("Old $operation sent after room replacement (stopFirst=$stopFirst)",
                    messagesBefore, fixture.transport.sent.size)
                assertTrue("Old cache result was marked ready in replacement room",
                    fixture.events.none { it is TourAssetTransferEvent.AssetReady })
                assertTrue(fixture.service.readyFilesByAssetID.isEmpty())
            } finally { fixture.close() }
        }
    }

    private class BlockingCache(private val operation: Operation, private val completeFile: File) : TourAssetCache {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)

        private fun block() {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS)) { "Blocking cache was never released" }
        }

        override fun readyFile(sha256: String, expectedLength: Long): File? {
            if (operation != Operation.READY_FILE) return null
            block()
            return completeFile
        }

        override fun resumeOffset(sha256: String, expectedLength: Long): Long {
            if (operation == Operation.RESUME_OFFSET) block()
            return 0
        }

        override fun ingest(chunk: AssetChunkPayload): AssetCacheIngestResult {
            block()
            return when (operation) {
                Operation.INGEST_PARTIAL -> AssetCacheIngestResult.Partial(1)
                Operation.INGEST_READY -> AssetCacheIngestResult.Ready(completeFile)
                Operation.INGEST_CHECKSUM_FAILURE -> throw AssetChecksumMismatchException("Expected injected checksum mismatch")
                Operation.INGEST_FAILURE -> throw AssetCacheException("Expected injected cache failure")
                else -> error("Unexpected ingest for $operation")
            }
        }

        override fun discardPartial(sha256: String) = Unit
    }

    private class Fixture(private val operation: Operation) {
        private val directory = Files.createTempDirectory("GetOverHereGuestGeneration-").toFile()
        private val file = directory.resolve("verified-cache-fixture.bin").apply { writeBytes(byteArrayOf(1, 2)) }
        private val hash = "a".repeat(64)
        private val oldRoom = UUID.randomUUID()
        private val participant = UUID.randomUUID()
        private val guide = UUID.randomUUID()
        private val manifest = TourPackManifestPayload(UUID.randomUUID(), 1, "Old room", listOf(
            TourAssetDescriptor("old-slide", TourAssetKind.SLIDE, hash, 2, 0, "image/jpeg")))
        val cache = BlockingCache(operation, file)
        val transport = LifecycleAssetTransport()
        val service = TourAssetTransferService(transport, cache)
        val events = CopyOnWriteArrayList<TourAssetTransferEvent>()
        private val barrier = CountDownLatch(1)
        private val barrierMessage = "guest-generation-barrier-${UUID.randomUUID()}"

        init {
            service.setEventHandler { event ->
                events.add(event)
                if (event is TourAssetTransferEvent.Failed && event.message == barrierMessage) barrier.countDown()
            }
            configure(oldRoom)
        }

        private fun configure(room: UUID) {
            service.configureSession(room, participant, "Guest", ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", room))
            service.joinTour("127.0.0.1")
        }

        fun configureNewRoom() = configure(UUID.randomUUID())

        fun beginBlockedOperation() {
            transport.emit(SessionAssetEvent.EnvelopeReceived(SessionEnvelope(lane = SessionLane.ASSET,
                kind = SessionMessageKind.TOUR_PACK_MANIFEST, sequence = 1, sessionId = oldRoom,
                senderId = guide, payload = manifest.encode())))
            if (operation == Operation.READY_FILE || operation == Operation.RESUME_OFFSET) return
            // The chunk follows the manifest on the same worker; no timing or mock socket is needed.
            transport.emit(SessionAssetEvent.EnvelopeReceived(SessionEnvelope(lane = SessionLane.ASSET,
                kind = SessionMessageKind.ASSET_CHUNK, sequence = 2, sessionId = oldRoom,
                senderId = guide, payload = AssetChunkPayload(hash, 0, 2, byteArrayOf(1)).encode())))
        }

        fun awaitWorkerBarrier() {
            transport.emit(SessionAssetEvent.Failed(barrierMessage))
            assertTrue("Asset worker did not finish old cache continuation", barrier.await(4, TimeUnit.SECONDS))
        }

        fun close() {
            cache.release.countDown()
            service.stop()
            check(directory.deleteRecursively()) { "Could not remove generation-test fixture directory" }
        }
    }
}
