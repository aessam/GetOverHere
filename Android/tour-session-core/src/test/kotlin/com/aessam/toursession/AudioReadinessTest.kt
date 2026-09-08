package com.aessam.toursession

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AudioReadinessTest {
    @Test fun everyStateAndRevisionRoundTrips() {
        for (status in AudioReadinessStatus.entries) {
            for (revision in listOf(0uL, 1uL, 0x0102030405060708uL, ULong.MAX_VALUE)) {
                val value = AudioReadinessPayload(status, revision)
                assertEquals(value, AudioReadinessPayload.decode(value.encode()))
            }
        }
        assertArrayEquals(byteArrayOf(1, 2, 1, 2, 3, 4, 5, 6, 7, 8),
            AudioReadinessPayload(AudioReadinessStatus.PLAYING, 0x0102030405060708uL).encode())
        assertEquals(SessionLane.CONTROL, SessionMessageKind.AUDIO_STATUS.requiredLane)
    }

    @Test fun rejectsUnknownAndNonCanonicalPayloads() {
        val valid = AudioReadinessPayload(AudioReadinessStatus.PLAYING, 1uL).encode()
        for (size in 0 until valid.size) {
            assertThrows(IllegalArgumentException::class.java) { AudioReadinessPayload.decode(valid.copyOf(size)) }
        }
        assertThrows(IllegalArgumentException::class.java) { AudioReadinessPayload.decode(valid + 0.toByte()) }
        for ((offset, value) in listOf(0 to 2, 1 to 0, 1 to 5)) {
            val invalid = valid.copyOf().apply { this[offset] = value.toByte() }
            assertThrows(IllegalArgumentException::class.java) { AudioReadinessPayload.decode(invalid) }
        }
    }
}
