package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.OfflineMapPack
import com.aessam.comeoverhere.service.OfflineMapPackException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64

class OfflineMapPackTest {
    @Test
    fun localPmTilesPlaceholderResolvesToAppOwnedFile() {
        val archive = Files.createTempFile("tour map ", ".pmtiles").toFile()
        try {
            archive.writeBytes(minimalArchiveBytes())
            OfflineMapPack.validateArchive(archive)

            val configuration = OfflineMapPack.configuration(styleBytes(), archive)

            assertTrue(configuration.styleJSON.contains("pmtiles://file:///"))
            assertTrue(configuration.styleJSON.contains("%20"))
            assertFalse(configuration.styleJSON.contains(OfflineMapPack.ARCHIVE_PLACEHOLDER))
        } finally {
            assertTrue(archive.delete())
        }
    }

    @Test
    fun networkResourcesAreRejected() {
        val style = """
            {"version":8,"sources":{"tour":{"type":"vector","url":"https://example.com/map.json"}},"layers":[]}
        """.trimIndent().encodeToByteArray()

        assertThrows(OfflineMapPackException::class.java) {
            OfflineMapPack.configuration(style, Files.createTempFile("map", ".pmtiles").toFile())
        }
    }

    @Test
    fun pmTilesMagicWithoutCompleteHeaderIsRejected() {
        val archive = Files.createTempFile("truncated-", ".pmtiles").toFile()
        try {
            archive.writeBytes("PMTiles\u0003".encodeToByteArray())

            assertThrows(OfflineMapPackException::class.java) {
                OfflineMapPack.validateArchive(archive)
            }
        } finally {
            assertTrue(archive.delete())
        }
    }

    @Test
    fun pmTilesSectionsOutsideFileAreRejected() {
        val archive = Files.createTempFile("invalid-offset-", ".pmtiles").toFile()
        try {
            val bytes = minimalArchiveBytes()
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).putLong(56, Long.MAX_VALUE)
            archive.writeBytes(bytes)

            assertThrows(OfflineMapPackException::class.java) {
                OfflineMapPack.validateArchive(archive)
            }
        } finally {
            assertTrue(archive.delete())
        }
    }

    companion object {
        fun styleBytes(): ByteArray = """
            {"version":8,"sources":{"tour":{"type":"raster","url":"getoverhere://map-archive","tileSize":256}},"layers":[{"id":"tour","type":"raster","source":"tour"}]}
        """.trimIndent().encodeToByteArray()

        fun minimalArchiveBytes(): ByteArray {
            val png = Base64.getDecoder().decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mM0NLxTDwADmAG/Djok1gAAAABJRU5ErkJggg==",
            )
            val directory = byteArrayOf(1, 0, 1, png.size.toByte(), 1)
            val metadata = "{}".encodeToByteArray()
            val rootOffset = 127L
            val metadataOffset = rootOffset + directory.size
            val tileOffset = metadataOffset + metadata.size
            val header = ByteBuffer.allocate(127).order(ByteOrder.LITTLE_ENDIAN)
            header.put("PMTiles".encodeToByteArray())
            header.put(3)
            header.putLong(rootOffset)
            header.putLong(directory.size.toLong())
            header.putLong(metadataOffset)
            header.putLong(metadata.size.toLong())
            header.putLong(tileOffset)
            header.putLong(0)
            header.putLong(tileOffset)
            header.putLong(png.size.toLong())
            header.putLong(1)
            header.putLong(1)
            header.putLong(1)
            header.put(1)
            header.put(1)
            header.put(1)
            header.put(2)
            header.put(0)
            header.put(0)
            return header.array() + directory + metadata + png
        }
    }
}
