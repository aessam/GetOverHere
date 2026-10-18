package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.TourPackImporter
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.TourPackException
import com.aessam.toursession.TourSessionFixtures
import com.aessam.toursession.lowercaseHex
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/** Mirrors TourPackImporterTests.swift (ADR-080). */
class TourPackImporterTest {
    private val assets = TourSessionFixtures.tourPackFixtureAssets()
    private val hashes = assets.map { MessageDigest.getInstance("SHA-256").digest(it).lowercaseHex() }

    private fun workspace(pack: ByteArray, body: (File, FileTourAssetCache) -> Unit) {
        val root = Files.createTempDirectory("GetOverHerePackTests").toFile()
        try {
            val file = File(root, "fixture.gohtour").apply { writeBytes(pack) }
            body(file, FileTourAssetCache(File(root, "cache")))
        } finally {
            check(root.deleteRecursively()) { "Temporary pack cleanup failed: $root" }
        }
    }

    @Test fun importsAndDeduplicates() = workspace(TourSessionFixtures.tourPackFixture()) { file, cache ->
        // Small chunks so multi-chunk ingestion is exercised on 13-byte assets.
        val importer = TourPackImporter(cache, chunkSize = 4)
        val first = importer.importPack(file)
        assertEquals(3, first.imported)
        assertEquals(0, first.alreadyCached)
        assertEquals("Fixture Tour", first.manifest.displayName)
        hashes.zip(assets).forEach { (hash, bytes) ->
            val ready = cache.readyFile(hash, bytes.size.toLong())
            assertNotNull(ready)
            assertArrayEquals(bytes, ready!!.readBytes())
        }
        val second = importer.importPack(file)
        assertEquals(0, second.imported)
        assertEquals(3, second.alreadyCached)
    }

    @Test fun corruptedPackWritesNothing() {
        val bytes = TourSessionFixtures.tourPackFixture().also { it[471] = (it[471].toInt() xor 1).toByte() }
        workspace(bytes) { file, cache ->
            val error = assertThrows(TourPackException::class.java) { TourPackImporter(cache).importPack(file) }
            assertEquals("trailerMismatch", error.reason)
            hashes.zip(assets).forEach { (hash, asset) ->
                assertNull(cache.readyFile(hash, asset.size.toLong()))
                assertEquals(0L, cache.resumeOffset(hash, asset.size.toLong()))
            }
        }
    }

    @Test fun replacesPartial() = workspace(TourSessionFixtures.tourPackFixture()) { file, cache ->
        val asset = assets[0]
        cache.ingest(AssetChunkPayload(hashes[0], 0, asset.size.toLong(), asset.copyOfRange(0, 5)))
        assertEquals(3, TourPackImporter(cache).importPack(file).imported)
        assertArrayEquals(asset, cache.readyFile(hashes[0], asset.size.toLong())!!.readBytes())
    }
}
