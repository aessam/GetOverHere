package com.aessam.comeoverhere.service

import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

data class OfflineMapConfiguration(
    val styleJSON: String,
    val archiveFile: File,
)

class OfflineMapPackException(message: String) : IllegalArgumentException(message)

object OfflineMapPack {
    const val ARCHIVE_PLACEHOLDER = "getoverhere://map-archive"
    const val MAXIMUM_STYLE_BYTES = 2 * 1_024 * 1_024
    private val json = Json { ignoreUnknownKeys = false }
    private val pmTilesHeader = byteArrayOf(0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73, 0x03)
    private const val PMTILES_HEADER_BYTE_COUNT = 127
    private const val MAXIMUM_ROOT_DIRECTORY_END = 16_384L

    fun resolve(
        manifest: TourPackManifestPayload,
        filesByAssetID: Map<String, File>,
    ): OfflineMapConfiguration {
        val style = manifest.assets.firstOrNull { it.kind == TourAssetKind.MAP_STYLE }
            ?: throw OfflineMapPackException("The tour pack has no map style")
        val archive = manifest.assets.firstOrNull { it.kind == TourAssetKind.MAP_ARCHIVE }
            ?: throw OfflineMapPackException("The tour pack has no PMTiles archive")
        val styleFile = filesByAssetID[style.assetID]
            ?: throw OfflineMapPackException("The offline map style is not ready")
        val archiveFile = filesByAssetID[archive.assetID]
            ?: throw OfflineMapPackException("The offline map archive is not ready")
        validateArchive(archiveFile)
        return configuration(styleFile.readBytes(), archiveFile)
    }

    fun configuration(styleBytes: ByteArray, archiveFile: File): OfflineMapConfiguration {
        if (styleBytes.size > MAXIMUM_STYLE_BYTES) {
            throw OfflineMapPackException("Invalid offline map style: style exceeds 2 MiB")
        }
        val root = runCatching { json.parseToJsonElement(styleBytes.decodeToString()).jsonObject }
            .getOrElse { throw OfflineMapPackException("Invalid offline map style: ${it.message}") }
        if (root["version"]?.jsonPrimitive?.content != "8") {
            throw OfflineMapPackException("Invalid offline map style: root must be a MapLibre style version 8 object")
        }
        rejectRemoteResource(root["glyphs"])
        rejectRemoteResource(root["sprite"])
        val sources = root["sources"] as? JsonObject
            ?: throw OfflineMapPackException("Invalid offline map style: sources must be an object")
        if (sources.isEmpty()) {
            throw OfflineMapPackException("Invalid offline map style: sources must not be empty")
        }

        var replacementCount = 0
        val resolvedSources = buildJsonObject {
            sources.forEach { (sourceID, element) ->
                val source = element as? JsonObject
                    ?: throw OfflineMapPackException("Invalid offline map style: source $sourceID must be an object")
                put(sourceID, buildJsonObject {
                    source.forEach { (key, value) ->
                        when {
                            key == "url" && value.jsonPrimitive.content == ARCHIVE_PLACEHOLDER -> {
                                put(key, JsonPrimitive("pmtiles://file://${archiveFile.toURI().rawPath}"))
                                replacementCount++
                            }
                            key == "url" -> {
                                rejectRemoteResource(value)
                                put(key, value)
                            }
                            key == "tiles" -> {
                                (value as? JsonArray)?.forEach(::rejectRemoteResource)
                                put(key, value)
                            }
                            else -> put(key, value)
                        }
                    }
                })
            }
        }
        if (replacementCount != 1) {
            throw OfflineMapPackException(
                "Invalid offline map style: exactly one source URL must equal $ARCHIVE_PLACEHOLDER",
            )
        }
        val resolved = buildJsonObject {
            root.forEach { (key, value) -> put(key, if (key == "sources") resolvedSources else value) }
        }
        return OfflineMapConfiguration(resolved.toString(), archiveFile)
    }

    fun validateArchive(file: File) {
        if (file.length() < PMTILES_HEADER_BYTE_COUNT) {
            throw OfflineMapPackException("The selected archive is not a PMTiles v3 file")
        }
        val header = file.inputStream().use { it.readUpTo(PMTILES_HEADER_BYTE_COUNT) }
        if (!header.copyOfRange(0, pmTilesHeader.size).contentEquals(pmTilesHeader)) {
            throw OfflineMapPackException("The selected archive is not a PMTiles v3 file")
        }
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val rootOffset = buffer.getLong(8)
        val rootLength = buffer.getLong(16)
        val metadataOffset = buffer.getLong(24)
        val metadataLength = buffer.getLong(32)
        val leafOffset = buffer.getLong(40)
        val leafLength = buffer.getLong(48)
        val tileOffset = buffer.getLong(56)
        val tileLength = buffer.getLong(64)
        val addressedTiles = buffer.getLong(72)
        val tileEntries = buffer.getLong(80)
        val tileContents = buffer.getLong(88)
        val size = file.length()
        val valid = rootLength > 0 && metadataLength > 0 && tileLength > 0 &&
            addressedTiles > 0 && tileEntries > 0 && tileContents > 0 &&
            sectionFits(rootOffset, rootLength, size) &&
            sectionFits(metadataOffset, metadataLength, size) &&
            sectionFits(leafOffset, leafLength, size) &&
            sectionFits(tileOffset, tileLength, size) &&
            rootOffset >= PMTILES_HEADER_BYTE_COUNT &&
            rootOffset <= MAXIMUM_ROOT_DIRECTORY_END - rootLength &&
            header[97].toInt() in 1..4 &&
            header[98].toInt() in 1..4 &&
            header[99].toInt() in 1..6 &&
            header[100].toUByte() <= header[101].toUByte()
        if (!valid) throw OfflineMapPackException("The selected archive is not a PMTiles v3 file")
    }

    private fun sectionFits(offset: Long, length: Long, fileSize: Long): Boolean =
        offset >= 0 && length >= 0 && offset <= fileSize && length <= fileSize - offset

    private fun rejectRemoteResource(value: JsonElement?) {
        val url = (value as? JsonPrimitive)?.content ?: return
        if (url.startsWith("http://", true) || url.startsWith("https://", true)) {
            throw OfflineMapPackException("Offline map style references a network resource: $url")
        }
    }
}

internal fun InputStream.readUpTo(maximumByteCount: Int): ByteArray {
    require(maximumByteCount >= 0) { "Maximum byte count must not be negative" }
    val bytes = ByteArray(maximumByteCount)
    var offset = 0
    while (offset < bytes.size) {
        val count = read(bytes, offset, bytes.size - offset)
        if (count < 0) break
        if (count == 0) {
            val byte = read()
            if (byte < 0) break
            bytes[offset] = byte.toByte()
            offset += 1
        } else {
            offset += count
        }
    }
    return bytes.copyOf(offset)
}
