package com.aessam.comeoverhere.service

import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.TourPackArchive
import com.aessam.toursession.TourPackException
import com.aessam.toursession.TourPackManifestPayload
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

/**
 * Imports a `.gohtour` pack (ADR-080, TourPackFormat.md) into the hash-keyed asset cache.
 *
 * The pack is untrusted. The prefix (header, manifest, index) and the whole-file trailer are validated
 * before any asset is written; each asset then goes through the cache's normal chunk path, which checks
 * its SHA-256 on completion. Cached files are used only when the live session's authenticated manifest
 * names their hash. A shared content URI is first copied to an app-private file, then imported from it.
 */
class TourPackImporter(
    private val cache: TourAssetCache,
    private val chunkSize: Int = TourAssetTransferService.CHUNK_SIZE,
) {
    data class Outcome(val manifest: TourPackManifestPayload, val imported: Int, val alreadyCached: Int)

    fun importPack(file: File): Outcome = RandomAccessFile(file, "r").use { input ->
        val fileLength = input.length()
        val header = read(input, TourPackArchive.HEADER_LENGTH)
        val prefixLength = TourPackArchive.prefixLength(header)
        val prefix = header + read(input, prefixLength - TourPackArchive.HEADER_LENGTH)
        val layout = TourPackArchive.parsePrefix(prefix, fileLength)

        // Pass 1: the trailer covers every byte, so nothing is written from a truncated or altered file.
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(prefix)
        var remaining = layout.totalLength - layout.dataOffset - TourPackArchive.TRAILER_LENGTH
        while (remaining > 0) {
            val count = minOf(chunkSize.toLong(), remaining).toInt()
            digest.update(read(input, count))
            remaining -= count
        }
        if (!digest.digest().contentEquals(read(input, TourPackArchive.TRAILER_LENGTH))) {
            throw TourPackException("trailerMismatch")
        }

        // Pass 2: each asset through the cache's chunk path (it re-checks the SHA-256 at completion, which
        // also covers the file changing between the passes).
        var imported = 0
        var alreadyCached = 0
        for (entry in layout.entries) {
            val hash = entry.sha256Hex
            if (cache.readyFile(hash, entry.byteLength) != null) {
                alreadyCached++
                continue
            }
            // A partial left by an earlier over-the-air transfer would not start at offset 0.
            cache.discardPartial(hash)
            input.seek(entry.offset)
            var offset = 0L
            var result: AssetCacheIngestResult
            do {
                val count = minOf(chunkSize.toLong(), entry.byteLength - offset).toInt()
                result = cache.ingest(AssetChunkPayload(hash, offset, entry.byteLength, read(input, count)))
                offset += count
            } while (offset < entry.byteLength)
            if (result !is AssetCacheIngestResult.Ready) throw TourPackException("assetHashMismatch", hash)
            imported++
        }
        Outcome(layout.manifest, imported, alreadyCached)
    }

    private fun read(input: RandomAccessFile, count: Int): ByteArray {
        val bytes = ByteArray(count)
        try {
            input.readFully(bytes)
        } catch (error: java.io.EOFException) {
            throw TourPackException("truncated")
        }
        return bytes
    }
}
