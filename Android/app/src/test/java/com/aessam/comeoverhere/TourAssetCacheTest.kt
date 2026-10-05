package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.AssetCacheException
import com.aessam.comeoverhere.service.AssetCacheIngestResult
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.toursession.AssetChunkPayload
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.security.MessageDigest

class TourAssetCacheTest {
    @Test
    fun transferResumesVerifiesSha256AndRejectsCorruption() {
        val root = Files.createTempDirectory("GetOverHereAssetCacheTests-").toFile()
        try {
            val bytes = "offline-tour-asset".toByteArray()
            val hash = MessageDigest.getInstance("SHA-256")
                .digest(bytes)
                .joinToString("") { "%02x".format(it) }
            val firstCount = 7
            val firstCache = FileTourAssetCache(root)
            assertEquals(
                AssetCacheIngestResult.Partial(firstCount.toLong()),
                firstCache.ingest(
                    AssetChunkPayload(
                        hash,
                        0,
                        bytes.size.toLong(),
                        bytes.copyOfRange(0, firstCount),
                    ),
                ),
            )

            val resumedCache = FileTourAssetCache(root)
            assertEquals(firstCount.toLong(), resumedCache.resumeOffset(hash, bytes.size.toLong()))
            val ready = resumedCache.ingest(
                AssetChunkPayload(
                    hash,
                    firstCount.toLong(),
                    bytes.size.toLong(),
                    bytes.copyOfRange(firstCount, bytes.size),
                ),
            ) as AssetCacheIngestResult.Ready
            assertArrayEquals(bytes, ready.file.readBytes())
            assertEquals(ready.file, resumedCache.readyFile(hash, bytes.size.toLong()))

            val corruptCache = FileTourAssetCache(root.resolve("corrupt"))
            assertThrows(AssetCacheException::class.java) {
                corruptCache.ingest(
                    AssetChunkPayload(
                        hash,
                        0,
                        bytes.size.toLong(),
                        ByteArray(bytes.size) { 0xff.toByte() },
                    ),
                )
            }
            assertEquals(0, corruptCache.resumeOffset(hash, bytes.size.toLong()))
        } finally {
            assertTrue("Temporary asset cleanup failed", root.deleteRecursively())
        }
    }

    @Test
    fun lengthMismatchedCompleteEntryIsDeletedAndReportedMissing() {
        val root = Files.createTempDirectory("GetOverHereAssetCacheTests-").toFile()
        try {
            val bytes = "offline-tour-asset".toByteArray()
            val hash = MessageDigest.getInstance("SHA-256")
                .digest(bytes)
                .joinToString("") { "%02x".format(it) }
            val cache = FileTourAssetCache(root)
            val corruptComplete = root.resolve("complete").resolve(hash)
            corruptComplete.writeBytes(ByteArray(10))

            assertNull(cache.readyFile(hash, bytes.size.toLong()))
            assertFalse("corrupt entry must be removed", corruptComplete.exists())
            assertEquals(0, cache.resumeOffset(hash, bytes.size.toLong()))

            val ready = cache.ingest(
                AssetChunkPayload(hash, 0, bytes.size.toLong(), bytes),
            ) as AssetCacheIngestResult.Ready
            assertArrayEquals(bytes, ready.file.readBytes())
            assertEquals(ready.file, cache.readyFile(hash, bytes.size.toLong()))
        } finally {
            assertTrue("Temporary asset cleanup failed", root.deleteRecursively())
        }
    }

    @Test
    fun oversizedPartialIsDeletedAndResumeRestartsAtZero() {
        val root = Files.createTempDirectory("GetOverHereAssetCacheTests-").toFile()
        try {
            val bytes = "offline-tour-asset".toByteArray()
            val hash = MessageDigest.getInstance("SHA-256")
                .digest(bytes)
                .joinToString("") { "%02x".format(it) }
            val cache = FileTourAssetCache(root)
            val oversizedPartial = root.resolve("partial").resolve("$hash.part")
            oversizedPartial.writeBytes(ByteArray(30))

            assertEquals(0, cache.resumeOffset(hash, bytes.size.toLong()))
            assertFalse("oversized partial must be removed", oversizedPartial.exists())
        } finally {
            assertTrue("Temporary asset cleanup failed", root.deleteRecursively())
        }
    }
}
