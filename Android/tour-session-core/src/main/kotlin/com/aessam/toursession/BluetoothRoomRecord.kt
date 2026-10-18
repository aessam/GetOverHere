package com.aessam.toursession

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

/**
 * A prepared tour the guide will present (ADR-080 DSCN-2). Guests holding a pack with this ID show
 * "Tour ready" before joining; readiness itself is still decided by the session manifest's hashes.
 */
data class TourPackAdvert(val packID: UUID, val manifestVersion: Long)

/**
 * Public discovery only; GOR1/v1 and GOR2/v2 have the same 439-byte maximum.
 * Flags: 1 Android guide, 2 locked, 4 a [TourPackAdvert] (16-byte pack ID + u64 version) follows the name.
 */
data class BluetoothRoomRecord(
    val roomID: UUID,
    val guideID: UUID,
    val name: String,
    val isAndroid: Boolean,
    val isLocked: Boolean,
    val admissionVersion: Int = 1,
    val pack: TourPackAdvert? = null,
) {
    fun encode(): ByteArray {
        val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).encode(CharBuffer.wrap(name))
        val text = ByteArray(encoded.remaining()).also { encoded.get(it) }
        val packLength = if (pack == null) 0 else PACK_ADVERT_LENGTH
        require(text.size in 1..400 && 39 + text.size + packLength <= MAXIMUM_LENGTH && admissionVersion in 1..2) {
            "Invalid Bluetooth room record"
        }
        return ByteBuffer.allocate(39 + text.size + packLength).apply {
            put((if (admissionVersion == 1) "GOR1" else "GOR2").toByteArray(Charsets.US_ASCII))
            put(((if (isAndroid) 1 else 0) or (if (isLocked) 2 else 0) or (if (pack == null) 0 else 4)).toByte())
            putLong(roomID.mostSignificantBits); putLong(roomID.leastSignificantBits)
            putLong(guideID.mostSignificantBits); putLong(guideID.leastSignificantBits)
            putShort(text.size.toShort()); put(text)
            if (pack != null) {
                putLong(pack.packID.mostSignificantBits); putLong(pack.packID.leastSignificantBits)
                putLong(pack.manifestVersion)
            }
        }.array()
    }

    companion object {
        const val MAXIMUM_LENGTH = 439
        private const val PACK_ADVERT_LENGTH = 24

        fun decode(data: ByteArray): BluetoothRoomRecord {
            require(data.size in 40..439) { "Invalid Bluetooth room record length" }
            val buffer = ByteBuffer.wrap(data)
            val admissionVersion = when (buffer.int) {
                0x474f5231 -> 1
                0x474f5232 -> 2
                else -> throw IllegalArgumentException("Unsupported Bluetooth room record")
            }
            val flags = buffer.get().toInt() and 255
            require(flags <= 7) { "Invalid Bluetooth room flags" }
            val packLength = if (flags and 4 != 0) PACK_ADVERT_LENGTH else 0
            val room = UUID(buffer.long, buffer.long)
            val guide = UUID(buffer.long, buffer.long)
            val length = buffer.short.toInt() and 65535
            require(length == buffer.remaining() - packLength) { "Invalid Bluetooth room name length" }
            val nameBytes = ByteBuffer.wrap(data, buffer.position(), length)
            val name = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(nameBytes).toString()
            require(name.isNotEmpty()) { "Invalid Bluetooth room name" }
            buffer.position(buffer.position() + length)
            val pack = if (packLength == 0) null else TourPackAdvert(UUID(buffer.long, buffer.long), buffer.long)
            return BluetoothRoomRecord(room, guide, name, flags and 1 != 0, flags and 2 != 0, admissionVersion, pack)
        }
    }
}
