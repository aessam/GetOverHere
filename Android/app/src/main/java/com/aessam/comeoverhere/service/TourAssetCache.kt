package com.aessam.comeoverhere.service

import com.aessam.toursession.AssetChunkPayload
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

sealed class AssetCacheIngestResult {
    data class Partial(val nextOffset: Long) : AssetCacheIngestResult()
    data class Ready(val file: File) : AssetCacheIngestResult()
}

open class AssetCacheException(message: String) : IllegalArgumentException(message)

/** A complete transfer whose bytes do not hash to the requested SHA-256; the partial was deleted. */
class AssetChecksumMismatchException(message: String) : AssetCacheException(message)

interface TourAssetCache {
    fun readyFile(sha256: String, expectedLength: Long): File?
    fun resumeOffset(sha256: String, expectedLength: Long): Long
    fun ingest(chunk: AssetChunkPayload): AssetCacheIngestResult
    fun discardPartial(sha256: String)
}

class FileTourAssetCache(
    rootDirectory: File,
) : TourAssetCache {
    private val completeDirectory = File(rootDirectory, "complete")
    private val partialDirectory = File(rootDirectory, "partial")

    init {
        if (!completeDirectory.mkdirs() && !completeDirectory.isDirectory) {
            throw AssetCacheException("Could not create ${completeDirectory.path}")
        }
        if (!partialDirectory.mkdirs() && !partialDirectory.isDirectory) {
            throw AssetCacheException("Could not create ${partialDirectory.path}")
        }
    }

    @Synchronized
    override fun readyFile(sha256: String, expectedLength: Long): File? {
        val file = completeFile(sha256)
        if (!file.exists()) return null
        val actual = file.length()
        if (actual != expectedLength) {
            // Repair locally and report missing; a failed delete still throws (loud).
            if (!file.delete()) {
                throw AssetCacheException("Could not delete length-mismatched complete ${file.path}")
            }
            System.err.println(
                "Asset cache: removed length-mismatched complete entry $sha256 (expected $expectedLength, got $actual)",
            )
            return null
        }
        return file
    }

    @Synchronized
    override fun resumeOffset(sha256: String, expectedLength: Long): Long {
        if (readyFile(sha256, expectedLength) != null) return expectedLength
        val partial = partialFile(sha256)
        if (!partial.exists()) return 0
        val actual = partial.length()
        if (actual > expectedLength) {
            if (!partial.delete()) {
                throw AssetCacheException("Could not delete oversized partial ${partial.path}")
            }
            System.err.println("Asset cache: removed oversized partial $sha256 (expected $expectedLength, got $actual)")
            return 0
        }
        return actual
    }

    @Synchronized
    override fun ingest(chunk: AssetChunkPayload): AssetCacheIngestResult {
        readyFile(chunk.sha256, chunk.totalLength)?.let { return AssetCacheIngestResult.Ready(it) }
        val partial = partialFile(chunk.sha256)
        val currentLength = if (partial.exists()) partial.length() else 0
        if (currentLength != chunk.offset) {
            throw AssetCacheException(
                "Asset offset mismatch: expected $currentLength, got ${chunk.offset}",
            )
        }

        RandomAccessFile(partial, "rw").use { file ->
            file.seek(currentLength)
            file.write(chunk.bytes)
            file.fd.sync()
        }
        val nextOffset = chunk.offset + chunk.bytes.size
        if (nextOffset != chunk.totalLength) return AssetCacheIngestResult.Partial(nextOffset)

        val actualHash = sha256(partial)
        if (actualHash != chunk.sha256) {
            if (!partial.delete()) {
                throw AssetCacheException(
                    "Asset checksum mismatch and partial could not be deleted: expected ${chunk.sha256}, got $actualHash",
                )
            }
            throw AssetChecksumMismatchException("Asset checksum mismatch: expected ${chunk.sha256}, got $actualHash")
        }

        val complete = completeFile(chunk.sha256)
        Files.move(
            partial.toPath(),
            complete.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
        )
        return AssetCacheIngestResult.Ready(complete)
    }

    @Synchronized
    override fun discardPartial(sha256: String) {
        val partial = partialFile(sha256)
        if (partial.exists() && !partial.delete()) {
            throw AssetCacheException("Could not delete partial ${partial.path}")
        }
    }

    private fun completeFile(sha256: String): File {
        validate(sha256)
        return File(completeDirectory, sha256)
    }

    private fun partialFile(sha256: String): File {
        validate(sha256)
        return File(partialDirectory, "$sha256.part")
    }

    private fun validate(sha256: String) {
        if (sha256.length != 64 || sha256.any { it !in "0123456789abcdef" }) {
            throw AssetCacheException("Invalid lowercase SHA-256: $sha256")
        }
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
}
