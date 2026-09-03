package com.aessam.toursession

import java.util.UUID

/**
 * Canonical manifest tie-break: unsigned lexicographic order of the UTF-8 wire bytes,
 * shorter prefix first (ADR-041). `String.compareTo` is UTF-16 code-unit order and
 * `java.util.Arrays.compareUnsigned` is API 33+, so neither is usable here.
 */
private fun compareUtf8Bytes(a: String, b: String): Int {
    val left = a.toByteArray(Charsets.UTF_8)
    val right = b.toByteArray(Charsets.UTF_8)
    val shared = minOf(left.size, right.size)
    for (index in 0 until shared) {
        val difference = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
        if (difference != 0) return difference
    }
    return left.size - right.size
}

private fun utf8Key(value: String): List<Byte> = value.toByteArray(Charsets.UTF_8).toList()

data class SlideAssetDescriptor(
    val slideID: String,
    val sha256: String,
    val byteLength: Long,
    val order: Long,
    val mimeType: String,
) {
    init {
        validateSha256(sha256)
        require(byteLength >= 0)
        require(order in 0..0xffff_ffffL)
    }

    internal fun encode(writer: BinaryWriter) {
        writer.appendString(slideID)
        writer.append(sha256.hexToByteArray())
        writer.appendUInt64(byteLength)
        writer.appendUInt32(order)
        writer.appendString(mimeType)
    }

    companion object {
        internal fun decode(reader: BinaryReader): SlideAssetDescriptor = SlideAssetDescriptor(
            slideID = reader.readString(),
            sha256 = reader.readBytes(32).lowercaseHex(),
            byteLength = reader.readUInt64(),
            order = reader.readUInt32(),
            mimeType = reader.readString(),
        )

        internal fun validateSha256(value: String) {
            if (value.length != 64 || value != value.lowercase() || value.any { it !in "0123456789abcdef" }) {
                throw SessionProtocolException("invalid lowercase SHA-256: $value")
            }
        }
    }
}

class AssetManifestPayload(
    val deckID: UUID,
    val manifestVersion: Long,
    assets: List<SlideAssetDescriptor>,
) {
    // Same wire-byte dedup and tie-break as TourPackManifestPayload (ADR-041, DSCN-7).
    val assets: List<SlideAssetDescriptor> = assets.sortedWith(
        compareBy<SlideAssetDescriptor> { it.order }.thenComparator { a, b -> compareUtf8Bytes(a.slideID, b.slideID) },
    )

    init {
        if (assets.size > 0xffff) {
            throw SessionProtocolException("manifest has ${assets.size} assets; maximum is 65535")
        }
        val duplicate = assets.groupingBy { utf8Key(it.slideID) }.eachCount().entries.firstOrNull { it.value > 1 }
        if (duplicate != null) {
            val slideID = assets.first { utf8Key(it.slideID) == duplicate.key }.slideID
            throw SessionProtocolException("duplicate slide ID $slideID")
        }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUuid(deckID)
        writer.appendUInt64(manifestVersion)
        writer.appendUInt16(assets.size)
        assets.forEach { it.encode(writer) }
        return writer.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is AssetManifestPayload &&
        deckID == other.deckID &&
        manifestVersion == other.manifestVersion &&
        assets == other.assets

    override fun hashCode(): Int {
        var result = deckID.hashCode()
        result = 31 * result + manifestVersion.hashCode()
        result = 31 * result + assets.hashCode()
        return result
    }

    companion object {
        fun decode(data: ByteArray): AssetManifestPayload {
            val reader = BinaryReader(data)
            val deckID = reader.readUuid()
            val version = reader.readUInt64()
            val assets = List(reader.readUInt16()) { SlideAssetDescriptor.decode(reader) }
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return AssetManifestPayload(deckID, version, assets)
        }
    }
}

enum class TourAssetKind(val rawValue: Int) {
    SLIDE(1),
    MAP_ARCHIVE(2),
    MAP_STYLE(3),
    MAP_SPRITES(4),
    MAP_GLYPHS(5);

    companion object {
        fun fromRaw(raw: Int): TourAssetKind = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("invalid tour asset kind $raw")
    }
}

data class TourAssetDescriptor(
    val assetID: String,
    val kind: TourAssetKind,
    val sha256: String,
    val byteLength: Long,
    val order: Long,
    val mimeType: String,
) {
    init {
        SlideAssetDescriptor.validateSha256(sha256)
        require(byteLength >= 0)
        require(order in 0..0xffff_ffffL)
    }

    internal fun encode(writer: BinaryWriter) {
        writer.appendString(assetID)
        writer.appendUInt8(kind.rawValue)
        writer.append(sha256.hexToByteArray())
        writer.appendUInt64(byteLength)
        writer.appendUInt32(order)
        writer.appendString(mimeType)
    }

    companion object {
        internal fun decode(reader: BinaryReader): TourAssetDescriptor = TourAssetDescriptor(
            assetID = reader.readString(),
            kind = TourAssetKind.fromRaw(reader.readUInt8()),
            sha256 = reader.readBytes(32).lowercaseHex(),
            byteLength = reader.readUInt64(),
            order = reader.readUInt32(),
            mimeType = reader.readString(),
        )
    }
}

class TourPackManifestPayload(
    val packID: UUID,
    val manifestVersion: Long,
    val displayName: String,
    assets: List<TourAssetDescriptor>,
) {
    // Dedup and order on the exact UTF-8 wire bytes (ADR-041).
    val assets: List<TourAssetDescriptor> = assets.sortedWith(
        compareBy<TourAssetDescriptor> { it.order }.thenComparator { a, b -> compareUtf8Bytes(a.assetID, b.assetID) },
    )

    init {
        if (assets.size > 0xffff) {
            throw SessionProtocolException("manifest has ${assets.size} assets; maximum is 65535")
        }
        val duplicate = assets.groupingBy { utf8Key(it.assetID) }.eachCount().entries.firstOrNull { it.value > 1 }
        if (duplicate != null) {
            val assetID = assets.first { utf8Key(it.assetID) == duplicate.key }.assetID
            throw SessionProtocolException("duplicate tour asset ID $assetID")
        }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUuid(packID)
        writer.appendUInt64(manifestVersion)
        writer.appendString(displayName)
        writer.appendUInt16(assets.size)
        assets.forEach { it.encode(writer) }
        return writer.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is TourPackManifestPayload &&
        packID == other.packID &&
        manifestVersion == other.manifestVersion &&
        displayName == other.displayName &&
        assets == other.assets

    override fun hashCode(): Int {
        var result = packID.hashCode()
        result = 31 * result + manifestVersion.hashCode()
        result = 31 * result + displayName.hashCode()
        result = 31 * result + assets.hashCode()
        return result
    }

    companion object {
        fun decode(data: ByteArray): TourPackManifestPayload {
            val reader = BinaryReader(data)
            val packID = reader.readUuid()
            val version = reader.readUInt64()
            val displayName = reader.readString()
            val assets = List(reader.readUInt16()) { TourAssetDescriptor.decode(reader) }
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return TourPackManifestPayload(packID, version, displayName, assets)
        }
    }
}

class AssetChunkPayload(
    val sha256: String,
    val offset: Long,
    val totalLength: Long,
    val bytes: ByteArray,
) {
    init {
        SlideAssetDescriptor.validateSha256(sha256)
        if (offset < 0 || totalLength < 0 || offset > totalLength || bytes.size > totalLength - offset) {
            throw SessionProtocolException("asset chunk exceeds declared asset length")
        }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.append(sha256.hexToByteArray())
        writer.appendUInt64(offset)
        writer.appendUInt64(totalLength)
        writer.append(bytes)
        return writer.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is AssetChunkPayload &&
        sha256 == other.sha256 &&
        offset == other.offset &&
        totalLength == other.totalLength &&
        bytes.contentEquals(other.bytes)

    override fun hashCode(): Int = 31 * sha256.hashCode() + bytes.contentHashCode()

    companion object {
        fun decode(data: ByteArray): AssetChunkPayload {
            val reader = BinaryReader(data)
            val hash = reader.readBytes(32).lowercaseHex()
            val offset = reader.readUInt64()
            val totalLength = reader.readUInt64()
            val bytes = reader.readBytes(reader.remaining)
            return AssetChunkPayload(hash, offset, totalLength, bytes)
        }
    }
}

data class AssetRequestPayload(
    val sha256: String,
    val offset: Long,
) {
    init {
        SlideAssetDescriptor.validateSha256(sha256)
        require(offset >= 0)
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.append(sha256.hexToByteArray())
        writer.appendUInt64(offset)
        return writer.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray): AssetRequestPayload {
            val reader = BinaryReader(data)
            val hash = reader.readBytes(32).lowercaseHex()
            val offset = reader.readUInt64()
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return AssetRequestPayload(hash, offset)
        }
    }
}

enum class AssetTransferStatus(val rawValue: Int) {
    READY(1),
    FAILED(2);

    companion object {
        fun fromRaw(raw: Int): AssetTransferStatus = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("invalid asset status $raw")
    }
}

data class AssetStatusPayload(
    val sha256: String,
    val status: AssetTransferStatus,
    val byteLength: Long,
    val detail: String,
) {
    init {
        SlideAssetDescriptor.validateSha256(sha256)
        require(byteLength >= 0)
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.append(sha256.hexToByteArray())
        writer.appendUInt8(status.rawValue)
        writer.appendUInt64(byteLength)
        writer.appendString(detail)
        return writer.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray): AssetStatusPayload {
            val reader = BinaryReader(data)
            val hash = reader.readBytes(32).lowercaseHex()
            val status = AssetTransferStatus.fromRaw(reader.readUInt8())
            val byteLength = reader.readUInt64()
            val detail = reader.readString()
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return AssetStatusPayload(hash, status, byteLength, detail)
        }
    }
}
