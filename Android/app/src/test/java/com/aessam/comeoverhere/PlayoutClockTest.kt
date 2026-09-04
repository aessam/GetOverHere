package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.EncodedAudioFrameOfferResult
import com.aessam.toursession.EncodedAudioFramePayload
import com.aessam.toursession.SequencedEncodedAudioFrame
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Transport-level proof for ADR-045: the clock, not frame arrival, drives playout; a single lost
 * frame becomes exactly one silence frame of the negotiated duration; a decoder failure is
 * reported once. The scheduler is never started here; [UDPAudioPlane.PlayoutClock.tick] is driven
 * with an injected clock.
 */
class PlayoutClockTest {
    private val fixedNow = 1_000_000L

    @Test
    fun gapIsConcealedWithSilence() {
        val decoder = FakePlayoutDecoder()
        val emitted = mutableListOf<ByteArray>()
        val failures = AtomicInteger()
        val clock = UDPAudioPlane.PlayoutClock(decoder, { fixedNow }, { emitted += it }, { failures.incrementAndGet() })
        try {
            listOf(1L, 2L, 3L, 5L).forEach { sequence ->
                assertEquals(
                    EncodedAudioFrameOfferResult.ACCEPTED,
                    clock.offer(SequencedEncodedAudioFrame(sequence, decoder.payload(sequence.toByte())), fixedNow),
                )
            }
            repeat(5) { clock.tick() }

            // 16 kHz * 20 ms / 1000 * 1 channel * 2 bytes = 640 bytes of PCM16 silence.
            assertEquals(640, clock.silenceFrame.size)
            assertEquals(5, emitted.size)
            assertArrayEquals(byteArrayOf(1), emitted[0])
            assertArrayEquals(byteArrayOf(2), emitted[1])
            assertArrayEquals(byteArrayOf(3), emitted[2])
            assertEquals(640, emitted[3].size)
            assertTrue(emitted[3].all { it == 0.toByte() })
            assertArrayEquals(byteArrayOf(5), emitted[4])
            assertEquals(0, failures.get())
            assertEquals(4, decoder.decodeCount.get())
        } finally {
            clock.close()
        }
    }

    @Test
    fun decodeFailureReportsOnceAndStopsTheClock() {
        val decoder = FakePlayoutDecoder(failing = true)
        val emitted = mutableListOf<ByteArray>()
        val failures = AtomicInteger()
        val clock = UDPAudioPlane.PlayoutClock(decoder, { fixedNow }, { emitted += it }, { failures.incrementAndGet() })
        try {
            listOf(1L, 2L, 3L).forEach { sequence ->
                assertEquals(
                    EncodedAudioFrameOfferResult.ACCEPTED,
                    clock.offer(SequencedEncodedAudioFrame(sequence, decoder.payload(sequence.toByte())), fixedNow),
                )
            }
            repeat(3) { clock.tick() }

            assertEquals(1, failures.get())
            assertTrue(emitted.isEmpty())
            assertEquals(1, decoder.decodeCount.get())
        } finally {
            clock.close()
        }
        assertEquals(1, decoder.closeCount.get())
    }
}

private class FakePlayoutDecoder(private val failing: Boolean = false) : RealtimeAudioDecoderInterface {
    override val configuration = SessionAudioCodecConfiguration(SessionAudioCodec.OPUS, 16_000, 1, 20, 20_000)
    val decodeCount = AtomicInteger()
    val closeCount = AtomicInteger()

    fun payload(byte: Byte): EncodedAudioFramePayload =
        EncodedAudioFramePayload(configuration, 0, 500_000_000, byteArrayOf(byte))

    override fun decode(packet: ByteArray): ByteArray {
        decodeCount.incrementAndGet()
        if (failing) throw IllegalStateException("decoder rejected the packet")
        return packet.copyOf()
    }

    override fun close() {
        closeCount.incrementAndGet()
    }
}
