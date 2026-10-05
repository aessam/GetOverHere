package com.aessam.toursession

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

/** Public discovery only; GOR1/v1 and GOR2/v2 have the same 439-byte maximum. */
data class BluetoothRoomRecord(
    val roomID: UUID,
    val guideID: UUID,
    val name: String,
    val isAndroid: Boolean,
    val isLocked: Boolean,
    val admissionVersion: Int = 1,
) {
    fun encode(): ByteArray {
        val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).encode(CharBuffer.wrap(name))
        val text = ByteArray(encoded.remaining()).also { encoded.get(it) }
        require(text.size in 1..400 && admissionVersion in 1..2) { "Invalid Bluetooth room record" }
        return ByteBuffer.allocate(39 + text.size).apply {
            put((if (admissionVersion == 1) "GOR1" else "GOR2").toByteArray(Charsets.US_ASCII))
            put(((if (isAndroid) 1 else 0) or (if (isLocked) 2 else 0)).toByte())
            putLong(roomID.mostSignificantBits); putLong(roomID.leastSignificantBits)
            putLong(guideID.mostSignificantBits); putLong(guideID.leastSignificantBits)
            putShort(text.size.toShort()); put(text)
        }.array()
    }

    companion object {
        fun decode(data: ByteArray): BluetoothRoomRecord {
            require(data.size in 40..439) { "Invalid Bluetooth room record length" }
            val buffer = ByteBuffer.wrap(data)
            val admissionVersion = when (buffer.int) {
                0x474f5231 -> 1
                0x474f5232 -> 2
                else -> throw IllegalArgumentException("Unsupported Bluetooth room record")
            }
            val flags = buffer.get().toInt() and 255
            require(flags <= 3) { "Invalid Bluetooth room flags" }
            val room = UUID(buffer.long, buffer.long)
            val guide = UUID(buffer.long, buffer.long)
            val length = buffer.short.toInt() and 65535
            require(length == buffer.remaining()) { "Invalid Bluetooth room name length" }
            val name = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(buffer).toString()
            return BluetoothRoomRecord(room, guide, name, flags and 1 != 0, flags and 2 != 0, admissionVersion)
        }
    }
}
