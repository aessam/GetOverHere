package com.aessam.toursession

import java.nio.ByteBuffer

/** Renderer readiness, not evidence that a person heard audio. Identity is in the authenticated envelope. */
enum class AudioReadinessStatus(val rawValue: Int) {
    WAITING(1), PLAYING(2), INTERRUPTED(3), FAILED(4),
}

data class AudioReadinessPayload(val status: AudioReadinessStatus, val revision: ULong) {
    fun encode(): ByteArray = ByteBuffer.allocate(10).put(1).put(status.rawValue.toByte())
        .putLong(revision.toLong()).array()

    companion object {
        fun decode(bytes: ByteArray): AudioReadinessPayload {
            require(bytes.size == 10 && bytes[0] == 1.toByte()) { "Invalid audio readiness payload" }
            val status = AudioReadinessStatus.entries.firstOrNull { it.rawValue == bytes[1].toInt() }
                ?: throw IllegalArgumentException("Unknown audio readiness status")
            return AudioReadinessPayload(status, ByteBuffer.wrap(bytes, 2, 8).long.toULong())
        }
    }
}
