package com.aessam.toursession

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

/** Public discovery only; identical GOR1 bytes to Swift, maximum 439 bytes. */
data class BluetoothRoomRecord(
    val roomID: UUID,
    val guideID: UUID,
    val name: String,
    val isAndroid: Boolean,
    val isLocked: Boolean,
) {
    fun encode(): ByteArray {
        val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).encode(CharBuffer.wrap(name))
        val text = ByteArray(encoded.remaining()).also { encoded.get(it) }
        require(text.size in 1..400) { "Invalid Bluetooth room name length" }
        return ByteBuffer.allocate(39 + text.size).apply {
            put("GOR1".toByteArray(Charsets.US_ASCII))
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
            require(buffer.int == 0x474f5231) { "Unsupported Bluetooth room record" }
            val flags = buffer.get().toInt() and 255
            require(flags <= 3) { "Invalid Bluetooth room flags" }
            val room = UUID(buffer.long, buffer.long)
            val guide = UUID(buffer.long, buffer.long)
            val length = buffer.short.toInt() and 65535
            require(length == buffer.remaining()) { "Invalid Bluetooth room name length" }
            val name = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(buffer).toString()
            return BluetoothRoomRecord(room, guide, name, flags and 1 != 0, flags and 2 != 0)
        }
    }
}
