package com.aessam.toursession

import java.security.MessageDigest

/** Reason names match the Swift `TourPackError` cases. */
class TourPackException(val reason: String, detail: String = "") :
    SessionProtocolException(if (detail.isEmpty()) "tour pack: $reason" else "tour pack: $reason ($detail)")

/**
 * `.gohtour` container, GOHP v1 (ADR-080, TourPackFormat.md). Big-endian like GOH2:
 * header 16 ("GOHP" | version | flags | reserved u16 | manifestLength u32 | entryCount u32),
 * manifest (TourPackManifestPayload.encode(), unchanged), index (entryCount × sha256 32 | byteLength u64 |
 * offset u64, sorted by raw SHA-256, unique), contiguous asset data, and a SHA-256 trailer of every
 * preceding byte. A pack is untrusted input; its files are used only when the live session's
 * authenticated manifest names their hash. Must stay byte-identical to the Swift `TourPackArchive`.
 */
object TourPackArchive {
    val MAGIC: ByteArray = "GOHP".toByteArray(Charsets.US_ASCII)
    const val VERSION = 1
    const val HEADER_LENGTH = 16
    const val INDEX_ENTRY_LENGTH = 48
    const val TRAILER_LENGTH = 32
    const val MAXIMUM_MANIFEST_LENGTH = 1 shl 20
    const val MAXIMUM_ENTRY_COUNT = 4_096
    const val MAXIMUM_ENTRY_LENGTH = 512L shl 20
    const val MAXIMUM_TOTAL_LENGTH = 2L shl 30

    class Entry(val sha256: ByteArray, val byteLength: Long, val offset: Long) {
        val sha256Hex: String get() = sha256.lowercaseHex()
        override fun equals(other: Any?): Boolean = other is Entry &&
            sha256.contentEquals(other.sha256) && byteLength == other.byteLength && offset == other.offset
        override fun hashCode(): Int = (sha256.contentHashCode() * 31 + byteLength.hashCode()) * 31 + offset.hashCode()
    }

    data class Layout(
        val manifest: TourPackManifestPayload,
        val entries: List<Entry>,
        /** Length of header + manifest + index; the first asset starts here. */
        val dataOffset: Long,
        /** Whole file length including the trailer. */
        val totalLength: Long,
    )

    /** Header, manifest and index for [manifest], and where each asset will sit. */
    fun prefix(manifest: TourPackManifestPayload): Pair<ByteArray, Layout> {
        val lengths = HashMap<String, Long>()
        for (asset in manifest.assets) {
            val known = lengths[asset.sha256]
            if (known != null && known != asset.byteLength) throw TourPackException("inconsistentLength", asset.sha256)
            if (asset.byteLength > MAXIMUM_ENTRY_LENGTH) throw TourPackException("entryTooLarge", asset.sha256)
            lengths[asset.sha256] = asset.byteLength
        }
        // Lowercase hex sorts exactly like the raw digest bytes.
        val hashes = lengths.keys.sorted()
        if (hashes.size !in 1..MAXIMUM_ENTRY_COUNT) throw TourPackException("invalidEntryCount", "${hashes.size}")
        val manifestBytes = manifest.encode()
        if (manifestBytes.size !in 1..MAXIMUM_MANIFEST_LENGTH) throw TourPackException("invalidManifestLength", "${manifestBytes.size}")
        val dataOffset = (HEADER_LENGTH + manifestBytes.size + hashes.size * INDEX_ENTRY_LENGTH).toLong()
        var offset = dataOffset
        val entries = hashes.map { hash ->
            val length = lengths.getValue(hash)
            Entry(hash.hexToByteArray(), length, offset).also { offset += length }
        }
        val totalLength = offset + TRAILER_LENGTH
        if (totalLength > MAXIMUM_TOTAL_LENGTH) throw TourPackException("packTooLarge", "$totalLength")

        val writer = BinaryWriter(dataOffset.toInt())
        writer.append(MAGIC)
        writer.appendUInt8(VERSION)
        writer.appendUInt8(0)
        writer.appendUInt16(0)
        writer.appendUInt32(manifestBytes.size.toLong())
        writer.appendUInt32(entries.size.toLong())
        writer.append(manifestBytes)
        for (entry in entries) {
            writer.append(entry.sha256)
            writer.appendUInt64(entry.byteLength)
            writer.appendUInt64(entry.offset)
        }
        return writer.toByteArray() to Layout(manifest, entries, dataOffset, totalLength)
    }

    /** The whole-file trailer: SHA-256 of header, manifest, index and data. */
    fun trailer(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    /** In-memory writer for fixtures and small packs. [assets] maps lowercase SHA-256 hex to bytes. */
    fun write(manifest: TourPackManifestPayload, assets: Map<String, ByteArray>): ByteArray {
        val (prefix, layout) = prefix(manifest)
        val file = java.io.ByteArrayOutputStream(layout.totalLength.toInt())
        file.write(prefix)
        for (entry in layout.entries) {
            val hash = entry.sha256Hex
            val bytes = assets[hash] ?: throw TourPackException("missingAsset", hash)
            if (bytes.size.toLong() != entry.byteLength ||
                !MessageDigest.getInstance("SHA-256").digest(bytes).contentEquals(entry.sha256)
            ) throw TourPackException("assetHashMismatch", hash)
            file.write(bytes)
        }
        val body = file.toByteArray()
        return body + trailer(body)
    }

    /** Bytes an importer must read before [parsePrefix]: header, manifest and index. */
    fun prefixLength(header: ByteArray): Int {
        val (manifestLength, entryCount) = parseHeader(header)
        return HEADER_LENGTH + manifestLength + entryCount * INDEX_ENTRY_LENGTH
    }

    /** Validates everything except the asset hashes and the trailer, which need the data bytes. */
    fun parsePrefix(prefix: ByteArray, fileLength: Long): Layout {
        val (manifestLength, entryCount) = parseHeader(prefix)
        val dataOffset = HEADER_LENGTH + manifestLength + entryCount * INDEX_ENTRY_LENGTH
        if (prefix.size < dataOffset) throw TourPackException("truncated")
        val reader = BinaryReader(prefix.copyOfRange(HEADER_LENGTH, dataOffset))
        val manifest = TourPackManifestPayload.decode(reader.readBytes(manifestLength))

        val entries = ArrayList<Entry>(entryCount)
        var expectedOffset = dataOffset.toLong()
        for (index in 0 until entryCount) {
            val entry = Entry(reader.readBytes(32), reader.readUInt64(), reader.readUInt64())
            val previous = entries.lastOrNull()
            if (previous != null && previous.sha256Hex >= entry.sha256Hex) throw TourPackException("indexNotSorted")
            if (entry.byteLength < 0 || entry.byteLength > MAXIMUM_ENTRY_LENGTH) throw TourPackException("entryTooLarge", entry.sha256Hex)
            if (entry.offset != expectedOffset) throw TourPackException("offsetMismatch", "$index")
            expectedOffset += entry.byteLength
            entries += entry
        }

        val manifestLengths = HashMap<String, Long>()
        for (asset in manifest.assets) {
            val known = manifestLengths[asset.sha256]
            if (known != null && known != asset.byteLength) throw TourPackException("inconsistentLength", asset.sha256)
            manifestLengths[asset.sha256] = asset.byteLength
        }
        if (manifestLengths.keys != entries.map { it.sha256Hex }.toSet()) throw TourPackException("manifestIndexMismatch")
        for (entry in entries) {
            if (manifestLengths[entry.sha256Hex] != entry.byteLength) throw TourPackException("inconsistentLength", entry.sha256Hex)
        }

        val totalLength = expectedOffset + TRAILER_LENGTH
        if (totalLength > MAXIMUM_TOTAL_LENGTH) throw TourPackException("packTooLarge", "$totalLength")
        if (totalLength != fileLength) throw TourPackException("fileLengthMismatch", "expected $totalLength, actual $fileLength")
        return Layout(manifest, entries, dataOffset.toLong(), totalLength)
    }

    /** In-memory reader: full validation including every asset hash and the trailer. */
    fun read(file: ByteArray): Pair<Layout, Map<String, ByteArray>> {
        val layout = parsePrefix(file, file.size.toLong())
        val bodyLength = file.size - TRAILER_LENGTH
        if (!trailer(file.copyOfRange(0, bodyLength)).contentEquals(file.copyOfRange(bodyLength, file.size))) {
            throw TourPackException("trailerMismatch")
        }
        val assets = LinkedHashMap<String, ByteArray>()
        for (entry in layout.entries) {
            val bytes = file.copyOfRange(entry.offset.toInt(), (entry.offset + entry.byteLength).toInt())
            if (!MessageDigest.getInstance("SHA-256").digest(bytes).contentEquals(entry.sha256)) {
                throw TourPackException("assetHashMismatch", entry.sha256Hex)
            }
            assets[entry.sha256Hex] = bytes
        }
        return layout to assets
    }

    private fun parseHeader(data: ByteArray): Pair<Int, Int> {
        if (data.size < HEADER_LENGTH) throw TourPackException("truncated")
        val reader = BinaryReader(data.copyOfRange(0, HEADER_LENGTH))
        if (!reader.readBytes(4).contentEquals(MAGIC)) throw TourPackException("badMagic")
        val fileVersion = reader.readUInt8()
        if (fileVersion != VERSION) throw TourPackException("unsupportedVersion", "$fileVersion")
        if (reader.readUInt8() != 0 || reader.readUInt16() != 0) throw TourPackException("reservedBitsSet")
        val manifestLength = reader.readUInt32()
        if (manifestLength !in 1L..MAXIMUM_MANIFEST_LENGTH.toLong()) throw TourPackException("invalidManifestLength", "$manifestLength")
        val entryCount = reader.readUInt32()
        if (entryCount !in 1L..MAXIMUM_ENTRY_COUNT.toLong()) throw TourPackException("invalidEntryCount", "$entryCount")
        return manifestLength.toInt() to entryCount.toInt()
    }
}
