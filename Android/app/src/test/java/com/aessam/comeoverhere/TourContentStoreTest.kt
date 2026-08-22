package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.TourContentStore
import com.aessam.toursession.TourAssetKind
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID

class TourContentStoreTest {
    @Test
    fun importedSlidesAreHashedPersistedAndOrdered() {
        val root = Files.createTempDirectory("GetOverHereContentStore-").toFile()
        try {
            val store = TourContentStore(root)
            val packID = UUID.randomUUID()
            val firstBytes = "gate".toByteArray()
            val secondBytes = "court".toByteArray()
            store.beginPack(packID, "Alhambra")
            val first = store.importSlide(firstBytes, "image/jpeg")
            val second = store.importSlide(secondBytes, "image/png")
            val manifest = store.manifestPayload()

            assertEquals(packID, manifest.packID)
            assertEquals(2L, manifest.manifestVersion)
            assertEquals(listOf(first.assetID, second.assetID), manifest.assets.map { it.assetID })
            assertEquals(listOf(0L, 1L), manifest.assets.map { it.order })
            assertEquals(
                MessageDigest.getInstance("SHA-256").digest(firstBytes)
                    .joinToString("") { "%02x".format(it) },
                first.sha256,
            )
            assertArrayEquals(firstBytes, store.sourcesByAssetID.getValue(first.assetID).readBytes())
            assertArrayEquals(secondBytes, store.sourcesByAssetID.getValue(second.assetID).readBytes())
        } finally {
            assertTrue(root.deleteRecursively())
        }
    }

    @Test
    fun slidesCanBeReorderedAndRemoved() {
        val root = Files.createTempDirectory("GetOverHereContentEdit-").toFile()
        try {
            val store = TourContentStore(root)
            store.beginPack(UUID.randomUUID(), "Alhambra")
            val first = store.importSlide("one".toByteArray(), "image/jpeg")
            val second = store.importSlide("two".toByteArray(), "image/jpeg")
            val third = store.importSlide("three".toByteArray(), "image/jpeg")

            store.moveSlide(third.assetID, 0)
            assertEquals(
                listOf(third.assetID, first.assetID, second.assetID),
                store.manifestPayload().assets.filter { it.kind == TourAssetKind.SLIDE }.map { it.assetID },
            )
            assertEquals(
                listOf(0L, 1L, 2L),
                store.manifestPayload().assets.filter { it.kind == TourAssetKind.SLIDE }.map { it.order },
            )

            store.removeSlide(first.assetID)
            val manifest = store.manifestPayload()
            assertEquals(5L, manifest.manifestVersion)
            assertEquals(
                listOf(third.assetID, second.assetID),
                manifest.assets.filter { it.kind == TourAssetKind.SLIDE }.map { it.assetID },
            )
            assertEquals(listOf(0L, 1L), manifest.assets.filter { it.kind == TourAssetKind.SLIDE }.map { it.order })
            assertEquals(null, store.sourcesByAssetID[first.assetID])
        } finally {
            assertTrue(root.deleteRecursively())
        }
    }

    @Test
    fun offlineMapIsCopiedHashedAndManifested() {
        val root = Files.createTempDirectory("GetOverHereMapStore-").toFile()
        val archive = Files.createTempFile("GetOverHereMap-", ".pmtiles").toFile()
        try {
            val archiveBytes = OfflineMapPackTest.minimalArchiveBytes()
            archive.writeBytes(archiveBytes)
            val store = TourContentStore(root)
            store.beginPack(UUID.randomUUID(), "Alhambra")

            store.importOfflineMap(OfflineMapPackTest.styleBytes(), archive)

            val manifest = store.manifestPayload()
            assertEquals(1L, manifest.manifestVersion)
            assertEquals(1, manifest.assets.count { it.kind == TourAssetKind.MAP_STYLE })
            assertEquals(1, manifest.assets.count { it.kind == TourAssetKind.MAP_ARCHIVE })
            val storedArchive = manifest.assets.first { it.kind == TourAssetKind.MAP_ARCHIVE }
            assertArrayEquals(archiveBytes, store.sourcesByAssetID.getValue(storedArchive.assetID).readBytes())
        } finally {
            assertTrue(root.deleteRecursively())
            assertTrue(archive.delete())
        }
    }
}
