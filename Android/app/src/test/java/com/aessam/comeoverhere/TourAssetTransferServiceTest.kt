package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.service.AssetCacheIngestResult
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.TourAssetTransferEvent
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
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
            val bytes = ByteArray(150_000) { (it % 251).toByte() }
            val mapBytes = ByteArray(80_000) { ((it * 7) % 251).toByte() }
            source.writeBytes(bytes)
            mapSource.writeBytes(mapBytes)
            val hash = MessageDigest.getInstance("SHA-256")
                .digest(bytes)
                .joinToString("") { "%02x".format(it) }
            val mapHash = MessageDigest.getInstance("SHA-256")
                .digest(mapBytes)
                .joinToString("") { "%02x".format(it) }
            val asset = TourAssetDescriptor(
                "gate-left",
                TourAssetKind.SLIDE,
                hash,
                bytes.size.toLong(),
                0,
                "image/jpeg",
            )
            val mapAsset = TourAssetDescriptor(
                "alhambra-map",
                TourAssetKind.MAP_ARCHIVE,
                mapHash,
                mapBytes.size.toLong(),
                1,
                "application/vnd.pmtiles",
            )
            val packID = UUID.randomUUID()
            val manifest = TourPackManifestPayload(
                packID,
                1,
                "Alhambra",
                listOf(asset, mapAsset),
            )
            val guideCache = FileTourAssetCache(root.resolve("guide-cache"))
            val guestCache = FileTourAssetCache(root.resolve("guest-cache"))
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
            val guestReady = CountDownLatch(1)
            val guestMapReady = CountDownLatch(1)
            val guideReady = CountDownLatch(1)
            val emptyManifestReceived = CountDownLatch(1)
            val readyFile = AtomicReference<java.io.File>()
            val readyMapFile = AtomicReference<java.io.File>()
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
                        if (event.assetID == "gate-left") {
                            readyFile.set(event.file)
                            guestReady.countDown()
                        } else if (event.assetID == "alhambra-map") {
                            readyMapFile.set(event.file)
                            guestMapReady.countDown()
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
                val credential = com.aessam.toursession.SessionCredential.derive("23456789AB", sessionID)
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
                    ),
                )

                assertTrue("Guest asset was not ready", guestReady.await(5, TimeUnit.SECONDS))
                assertArrayEquals(bytes, readyFile.get().readBytes())
                assertTrue("Guest map archive was not ready", guestMapReady.await(5, TimeUnit.SECONDS))
                assertArrayEquals(mapBytes, readyMapFile.get().readBytes())
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
                assertArrayEquals(bytes, readyFile.get().readBytes())
                assertArrayEquals(mapBytes, readyMapFile.get().readBytes())
                assertNull(failure.get())
            } finally {
                guest.stop()
                guide.stop()
            }
        } finally {
            assertTrue("Temporary transfer cleanup failed", root.deleteRecursively())
        }
    }
}
