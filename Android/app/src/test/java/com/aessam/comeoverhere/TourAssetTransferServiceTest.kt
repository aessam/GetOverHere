package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.service.AssetCacheIngestResult
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.TourAssetTransferEvent
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.AssetRequestPayload
import com.aessam.toursession.AssetStatusPayload
import com.aessam.toursession.AssetTransferStatus
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class TourAssetTransferServiceTest {
    @Test
    fun interruptedTransferResumesAndReportsVerifiedParticipantReadiness() {
        val root = Files.createTempDirectory("GetOverHereTransferTests-").toFile()
        try {
            val source = root.resolve("source.bin")
            val mapSource = root.resolve("tour.pmtiles")
            val styleSource = root.resolve("style.json")
            val spritesSource = root.resolve("sprites.png")
            val bytes = ByteArray(150_000) { (it % 251).toByte() }
            val mapBytes = ByteArray(80_000) { ((it * 7) % 251).toByte() }
            val styleBytes = ByteArray(3_000) { ((it * 11) % 251).toByte() }
            val spritesBytes = ByteArray(70_000) { ((it * 13) % 251).toByte() }
            source.writeBytes(bytes)
            mapSource.writeBytes(mapBytes)
            styleSource.writeBytes(styleBytes)
            spritesSource.writeBytes(spritesBytes)
            val hash = sha256(bytes)
            val mapHash = sha256(mapBytes)
            val styleHash = sha256(styleBytes)
            val spritesHash = sha256(spritesBytes)
            val asset = TourAssetDescriptor("gate-left", TourAssetKind.SLIDE, hash, bytes.size.toLong(), 0, "image/jpeg")
            val mapAsset = TourAssetDescriptor(
                "alhambra-map",
                TourAssetKind.MAP_ARCHIVE,
                mapHash,
                mapBytes.size.toLong(),
                1,
                "application/vnd.pmtiles",
            )
            val styleAsset = TourAssetDescriptor(
                "alhambra-style",
                TourAssetKind.MAP_STYLE,
                styleHash,
                styleBytes.size.toLong(),
                2,
                "application/json",
            )
            val spritesAsset = TourAssetDescriptor(
                "alhambra-sprites",
                TourAssetKind.MAP_SPRITES,
                spritesHash,
                spritesBytes.size.toLong(),
                3,
                "image/png",
            )
            val packID = UUID.randomUUID()
            val manifest = TourPackManifestPayload(
                packID,
                1,
                "Alhambra",
                listOf(asset, mapAsset, styleAsset, spritesAsset),
            )
            val guideCache = FileTourAssetCache(root.resolve("guide-cache"))
            val guestCacheRoot = root.resolve("guest-cache")
            val guestCache = FileTourAssetCache(guestCacheRoot)
            assertEquals(
                AssetCacheIngestResult.Partial(65_536),
                guestCache.ingest(
                    AssetChunkPayload(
                        hash,
                        0,
                        bytes.size.toLong(),
                        bytes.copyOfRange(0, 65_536),
                    ),
                ),
            )
            // A corrupt complete entry for the map (wrong length) must be repaired, not abort the pack.
            guestCacheRoot.resolve("complete").resolve(mapHash).writeBytes(ByteArray(10))

            val guideID = UUID.randomUUID()
            val guestID = UUID.randomUUID()
            val sessionID = UUID.randomUUID()
            val guide = TourAssetTransferService(
                LocalSessionAssetTransport(50_012),
                guideCache,
            )
            val guest = TourAssetTransferService(
                LocalSessionAssetTransport(50_012),
                guestCache,
            )
            val expectedReady = setOf("gate-left", "alhambra-map", "alhambra-style", "alhambra-sprites")
            val readyFiles = ConcurrentHashMap<String, File>()
            val allGuestReady = CountDownLatch(expectedReady.size)
            val guideReady = CountDownLatch(1)
            val emptyManifestReceived = CountDownLatch(1)
            val failure = AtomicReference<String>()
            guide.setEventHandler { event ->
                when (event) {
                    is TourAssetTransferEvent.ParticipantReady -> {
                        assertEquals(guestID, event.participantID)
                        guideReady.countDown()
                    }
                    is TourAssetTransferEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }
            guest.setEventHandler { event ->
                when (event) {
                    is TourAssetTransferEvent.AssetReady -> {
                        if (event.assetID in expectedReady && readyFiles.put(event.assetID, event.file) == null) {
                            allGuestReady.countDown()
                        }
                    }
                    is TourAssetTransferEvent.ManifestReceived -> {
                        if (event.manifest.manifestVersion == 0L) emptyManifestReceived.countDown()
                    }
                    is TourAssetTransferEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }

            try {
                val credential = SessionCredential.derive("23456789AB", sessionID)
                guide.configureSession(sessionID, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
                guest.configureSession(sessionID, guestID, "Guest", ParticipantPlatform.ANDROID, credential)
                guide.hostTourPack(
                    TourPackManifestPayload(packID, 0, "Alhambra", emptyList()),
                    emptyMap(),
                )
                guest.joinTour("127.0.0.1")
                assertTrue(
                    "Guest did not receive initial tour pack",
                    emptyManifestReceived.await(5, TimeUnit.SECONDS),
                )
                assertEquals(setOf(guestID), guide.connectedParticipantIDs)

                guide.hostTourPack(
                    manifest,
                    mapOf(
                        asset.assetID to source,
                        mapAsset.assetID to mapSource,
                        styleAsset.assetID to styleSource,
                        spritesAsset.assetID to spritesSource,
                    ),
                )

                assertTrue(
                    "Guest assets were not all ready: ${readyFiles.keys}",
                    allGuestReady.await(10, TimeUnit.SECONDS),
                )
                val readyFile = readyFiles.getValue("gate-left")
                val readyMapFile = readyFiles.getValue("alhambra-map")
                assertArrayEquals(bytes, readyFile.readBytes())
                assertArrayEquals(mapBytes, readyMapFile.readBytes())
                assertArrayEquals(styleBytes, readyFiles.getValue("alhambra-style").readBytes())
                assertArrayEquals(spritesBytes, readyFiles.getValue("alhambra-sprites").readBytes())
                assertTrue("Guide did not receive readiness", guideReady.await(5, TimeUnit.SECONDS))
                assertTrue(guide.isParticipantReady(guestID))
                assertNull(failure.get())
                assertNull(guide.lastError)
                assertNull(guest.lastError)

                val readyAfterRejoin = CountDownLatch(1)
                val readinessDropped = CountDownLatch(1)
                guide.setEventHandler { event ->
                    when (event) {
                        is TourAssetTransferEvent.ParticipantReady -> {
                            assertEquals(guestID, event.participantID)
                            readyAfterRejoin.countDown()
                        }
                        is TourAssetTransferEvent.ParticipantReadinessChanged -> {
                            if (event.readyCount == 0) readinessDropped.countDown()
                        }
                        is TourAssetTransferEvent.Failed -> failure.compareAndSet(null, event.message)
                        else -> Unit
                    }
                }
                guest.stop()
                assertTrue(
                    "Guide readiness count did not drop after disconnect",
                    readinessDropped.await(5, TimeUnit.SECONDS),
                )
                guest.joinTour("127.0.0.1")
                assertTrue(
                    "Cached guest did not become ready after rejoin",
                    readyAfterRejoin.await(5, TimeUnit.SECONDS),
                )
                assertEquals(setOf(guestID), guide.connectedParticipantIDs)
                assertTrue(guide.isParticipantReady(guestID))
                assertArrayEquals(bytes, readyFile.readBytes())
                assertArrayEquals(mapBytes, readyMapFile.readBytes())
                assertNull(failure.get())
            } finally {
                guest.stop()
                guide.stop()
            }
        } finally {
            assertTrue("Temporary transfer cleanup failed", root.deleteRecursively())
        }
    }

    // MARK: - Bounded, self-repairing guest pipeline over a recording transport

    @Test
    fun manifestRequestsAreCappedAtTwoInFlight() {
        val f = GuestFixture(mapOf("a" to 1_000, "b" to 70_000, "c" to 1_000, "d" to 1_000))
        try {
            // A wrong-length complete entry for B must be repaired without aborting the pack.
            f.writeCorruptCompleteEntry("b", 10)

            f.deliverManifest()
            f.awaitRequestCount(2)
            Thread.sleep(200)
            assertEquals("only two assets may be in flight", listOf(f.hash("a"), f.hash("b")), f.requests().map { it.sha256 })
            assertEquals(listOf(0L, 0L), f.requests().map { it.offset })

            f.deliverChunk("a", 0)
            f.awaitRequestCount(3)
            assertEquals(listOf(f.hash("a")), f.readyStatuses().map { it.sha256 })
            assertEquals(f.hash("c"), f.requests()[2].sha256)

            f.deliverChunk("b", 0)
            f.awaitRequestCount(4)
            assertEquals(f.hash("b"), f.requests()[3].sha256)
            assertEquals(65_536L, f.requests()[3].offset)
            Thread.sleep(100)
            assertEquals("D must wait for a free slot", 4, f.requests().size)

            f.deliverChunk("c", 0)
            f.awaitRequestCount(5)
            assertEquals(f.hash("d"), f.requests()[4].sha256)

            f.deliverChunk("b", 65_536)
            f.deliverChunk("d", 0)
            f.awaitReadyAssets(setOf("a", "b", "c", "d"))
            assertArrayEquals(f.bytes("b"), f.readyFile("b").readBytes())
            assertEquals(5, f.requests().size)
            assertTrue(f.failedStatuses().isEmpty())
            assertNull(f.service.lastError)
        } finally {
            f.close()
        }
    }

    @Test
    fun checksumMismatchIsReRequestedOnceAndRecovers() {
        val f = GuestFixture(mapOf("a" to 1_000))
        try {
            f.deliverManifest()
            f.awaitRequestCount(1)
            f.deliverCorruptChunk("a")
            f.awaitRequestCount(2)
            assertEquals(f.hash("a"), f.requests()[1].sha256)
            assertEquals(0L, f.requests()[1].offset)
            assertTrue(f.failedStatuses().isEmpty())
            assertTrue(f.failedEvents().isEmpty())

            f.deliverChunk("a", 0)
            f.awaitReadyAssets(setOf("a"))
            assertEquals(listOf(f.hash("a")), f.readyStatuses().map { it.sha256 })
            assertTrue(f.failedEvents().isEmpty())
            assertNull(f.service.lastError)
        } finally {
            f.close()
        }
    }

    @Test
    fun secondChecksumMismatchSendsFailedStatusAndReleasesSlot() {
        val f = GuestFixture(mapOf("a" to 1_000, "b" to 1_000, "c" to 1_000))
        try {
            f.deliverManifest()
            f.awaitRequestCount(2)
            f.deliverCorruptChunk("a")
            f.awaitRequestCount(3)
            assertEquals("first mismatch re-requests A", f.hash("a"), f.requests()[2].sha256)

            f.deliverChunk("b", 0)
            f.awaitRequestCount(4)
            assertEquals("B's slot goes to C", f.hash("c"), f.requests()[3].sha256)

            f.deliverCorruptChunk("a")
            awaitCondition("FAILED status for A") { f.failedStatuses().isNotEmpty() }
            assertEquals(listOf(f.hash("a")), f.failedStatuses().map { it.sha256 })
            assertTrue(f.failedStatuses().first().detail.contains("checksum mismatch"))
            assertFalse(f.failedEvents().isEmpty())
            Thread.sleep(200)
            assertEquals("no third request for A", 2, f.requests().count { it.sha256 == f.hash("a") })

            f.deliverChunk("c", 0)
            f.awaitReadyAssets(setOf("b", "c"))
            assertEquals(4, f.requests().size)
        } finally {
            f.close()
        }
    }

    /** Passes before G5 (no queue existed); guards the reset on Disconnected that the cap needs. */
    @Test
    fun disconnectResetsInFlightRequests() {
        val f = GuestFixture(mapOf("a" to 1_000, "b" to 1_000))
        try {
            f.deliverManifest()
            f.awaitRequestCount(2)

            f.transport.emit(SessionAssetEvent.Disconnected)
            f.deliverManifest()
            f.awaitRequestCount(4)
            assertEquals(
                listOf(f.hash("a"), f.hash("b"), f.hash("a"), f.hash("b")),
                f.requests().map { it.sha256 },
            )
            assertEquals(listOf(0L, 0L, 0L, 0L), f.requests().map { it.offset })

            f.deliverChunk("a", 0)
            f.deliverChunk("b", 0)
            f.awaitReadyAssets(setOf("a", "b"))
            assertTrue(f.failedStatuses().isEmpty())
            assertNull(f.service.lastError)
        } finally {
            f.close()
        }
    }

    @Test
    fun unansweredRequestReleasesSlotAfterDeadline() {
        val f = GuestFixture(mapOf("a" to 1_000, "b" to 1_000, "c" to 1_000, "d" to 1_000), inFlightDeadlineMillis = 300L)
        try {
            f.deliverManifest()
            f.awaitRequestCount(2)
            assertEquals(listOf(f.hash("a"), f.hash("b")), f.requests().map { it.sha256 })

            // Serve nothing: both deadlines expire, report FAILED, and free the slots for C and D.
            f.awaitRequestCount(4)
            assertEquals(f.hash("c"), f.requests()[2].sha256)
            assertEquals(f.hash("d"), f.requests()[3].sha256)
            // Both deadlines expire in the same instant; the assertions are order-independent like iOS.
            assertEquals(setOf(f.hash("a"), f.hash("b")), f.failedStatuses().map { it.sha256 }.toSet())
            assertEquals(
                listOf("no chunk received within 0.3 s", "no chunk received within 0.3 s"),
                f.failedStatuses().map { it.detail },
            )
            assertEquals(
                setOf("Asset a: no chunk received within 0.3 s", "Asset b: no chunk received within 0.3 s"),
                f.failedEvents().toSet(),
            )

            f.deliverChunk("c", 0)
            f.deliverChunk("d", 0)
            f.awaitReadyAssets(setOf("c", "d"))
            assertEquals(listOf(f.hash("c"), f.hash("d")), f.readyStatuses().map { it.sha256 })
            assertEquals(4, f.requests().size)
        } finally {
            f.close()
        }
    }

    // MARK: - Helpers

    /**
     * A guest [TourAssetTransferService] over G4's recording [LifecycleAssetTransport]: the test plays
     * the guide by delivering manifest and chunk envelopes and reads back requests and statuses.
     */
    private class GuestFixture(sizes: Map<String, Int>, inFlightDeadlineMillis: Long? = null) {
        val transport = LifecycleAssetTransport()
        val service: TourAssetTransferService
        val manifest: TourPackManifestPayload
        private val root = Files.createTempDirectory("GetOverHereGuestFixture-").toFile()
        private val cacheRoot = root.resolve("cache")
        private val guideID = UUID.randomUUID()
        private val sessionID = UUID.randomUUID()
        private val descriptors = mutableMapOf<String, TourAssetDescriptor>()
        private val contents = mutableMapOf<String, ByteArray>()
        private var sequence = 0L
        private val events = CopyOnWriteArrayList<TourAssetTransferEvent>()

        init {
            val assets = sizes.keys.sorted().mapIndexed { index, assetID ->
                val count = sizes.getValue(assetID)
                val seed = index + 3
                val data = ByteArray(count) { ((it * seed) % 251).toByte() }
                contents[assetID] = data
                TourAssetDescriptor(assetID, TourAssetKind.SLIDE, sha256(data), count.toLong(), index.toLong(), "image/jpeg")
                    .also { descriptors[assetID] = it }
            }
            manifest = TourPackManifestPayload(UUID.randomUUID(), 1, "Pack", assets)
            val cache = FileTourAssetCache(cacheRoot)
            service = if (inFlightDeadlineMillis != null) {
                TourAssetTransferService(transport, cache, inFlightDeadlineMillis)
            } else {
                TourAssetTransferService(transport, cache)
            }
            service.setEventHandler { events += it }
            service.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", sessionID),
            )
            service.joinTour("127.0.0.1")
        }

        fun close() {
            service.stop()
            assertTrue("Guest fixture cleanup failed", root.deleteRecursively())
        }

        fun hash(assetID: String): String = descriptors.getValue(assetID).sha256
        fun bytes(assetID: String): ByteArray = contents.getValue(assetID)

        fun requests(): List<AssetRequestPayload> =
            transport.sent.filter { it.kind == SessionMessageKind.ASSET_REQUEST }.map { AssetRequestPayload.decode(it.payload) }

        private fun statuses(): List<AssetStatusPayload> =
            transport.sent.filter { it.kind == SessionMessageKind.ASSET_STATUS }.map { AssetStatusPayload.decode(it.payload) }

        fun readyStatuses(): List<AssetStatusPayload> = statuses().filter { it.status == AssetTransferStatus.READY }
        fun failedStatuses(): List<AssetStatusPayload> = statuses().filter { it.status == AssetTransferStatus.FAILED }
        fun failedEvents(): List<String> = events.filterIsInstance<TourAssetTransferEvent.Failed>().map { it.message }
        fun readyAssetIDs(): Set<String> = events.filterIsInstance<TourAssetTransferEvent.AssetReady>().map { it.assetID }.toSet()

        fun readyFile(assetID: String): File {
            val file = service.readyFilesByAssetID[assetID]
            assertNotNull("asset $assetID must be ready", file)
            return file!!
        }

        fun writeCorruptCompleteEntry(assetID: String, byteCount: Int) {
            cacheRoot.resolve("complete").resolve(hash(assetID)).writeBytes(ByteArray(byteCount))
        }

        fun deliverManifest() = deliver(SessionMessageKind.TOUR_PACK_MANIFEST, manifest.encode())

        fun deliverChunk(assetID: String, offset: Long) {
            val data = bytes(assetID)
            val end = minOf(data.size, offset.toInt() + 65_536)
            val chunk = AssetChunkPayload(hash(assetID), offset, data.size.toLong(), data.copyOfRange(offset.toInt(), end))
            deliver(SessionMessageKind.ASSET_CHUNK, chunk.encode())
        }

        /** A full-length chunk of 0xFF bytes under the asset's real hash: the cache rejects it on verify. */
        fun deliverCorruptChunk(assetID: String) {
            val count = bytes(assetID).size
            check(count <= 65_536) { "corrupt chunk must be a single chunk" }
            val chunk = AssetChunkPayload(hash(assetID), 0, count.toLong(), ByteArray(count) { 0xff.toByte() })
            deliver(SessionMessageKind.ASSET_CHUNK, chunk.encode())
        }

        private fun deliver(kind: SessionMessageKind, payload: ByteArray) {
            sequence += 1
            transport.emit(
                SessionAssetEvent.EnvelopeReceived(
                    SessionEnvelope(
                        lane = SessionLane.ASSET,
                        kind = kind,
                        sequence = sequence,
                        sessionId = sessionID,
                        senderId = guideID,
                        payload = payload,
                    ),
                ),
            )
        }

        fun awaitRequestCount(count: Int) {
            awaitCondition("$count asset requests") { requests().size >= count }
            assertEquals("request burst exceeded the expected count", count, requests().size)
        }

        fun awaitReadyAssets(assetIDs: Set<String>) {
            awaitCondition("assets ready: $assetIDs") { readyAssetIDs().containsAll(assetIDs) }
        }
    }

    private companion object {
        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

        fun awaitCondition(description: String, timeoutMillis: Long = 5_000, condition: () -> Boolean) {
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (!condition()) {
                if (System.currentTimeMillis() > deadline) throw AssertionError("Timed out waiting for $description")
                Thread.sleep(5)
            }
        }
    }
}
