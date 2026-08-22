package com.aessam.comeoverhere.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class WiFiAwareProbeFrame(
    val kind: Kind,
    val sequence: Long,
    val sentAtNanoseconds: Long,
    val payload: ByteArray,
) {
    enum class Kind(val wireValue: Byte) {
        HELLO(1),
        PROBE(2),
        ECHO(3);

        companion object {
            fun fromWireValue(value: Byte): Kind = entries.firstOrNull { it.wireValue == value }
                ?: throw DecodeException("Invalid frame kind: ${value.toUByte()}")
        }
    }

    fun encode(): ByteArray = ByteBuffer.allocate(HEADER_SIZE + payload.size)
        .order(ByteOrder.BIG_ENDIAN)
        .putInt(MAGIC)
        .put(VERSION)
        .put(kind.wireValue)
        .putShort(0)
        .putLong(sequence)
        .putLong(sentAtNanoseconds)
        .putInt(payload.size)
        .put(payload)
        .array()

    override fun equals(other: Any?): Boolean =
        other is WiFiAwareProbeFrame &&
            kind == other.kind &&
            sequence == other.sequence &&
            sentAtNanoseconds == other.sentAtNanoseconds &&
            payload.contentEquals(other.payload)

    override fun hashCode(): Int {
        var result = kind.hashCode()
        result = 31 * result + sequence.hashCode()
        result = 31 * result + sentAtNanoseconds.hashCode()
        result = 31 * result + payload.contentHashCode()
        return result
    }

    class DecodeException(message: String) : IllegalArgumentException(message)

    companion object {
        const val HEADER_SIZE = 28
        private const val MAGIC = 0x474F4831
        private const val VERSION: Byte = 1

        fun decode(data: ByteArray): WiFiAwareProbeFrame {
            if (data.size < HEADER_SIZE) throw DecodeException("Frame header is truncated")

            val buffer = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
            if (buffer.int != MAGIC) throw DecodeException("Invalid frame magic")

            val version = buffer.get()
            if (version != VERSION) throw DecodeException("Unsupported frame version: ${version.toUByte()}")

            val kind = Kind.fromWireValue(buffer.get())
            buffer.short
            val sequence = buffer.long
            val sentAtNanoseconds = buffer.long
            val payloadLength = buffer.int
            val actualPayloadLength = buffer.remaining()
            if (payloadLength < 0 || payloadLength != actualPayloadLength) {
                throw DecodeException(
                    "Invalid payload length: expected $payloadLength, actual $actualPayloadLength"
                )
            }

            return WiFiAwareProbeFrame(
                kind = kind,
                sequence = sequence,
                sentAtNanoseconds = sentAtNanoseconds,
                payload = ByteArray(payloadLength).also(buffer::get),
            )
        }
    }
}
