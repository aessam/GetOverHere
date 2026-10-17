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

    @Test fun decoderCleanupFailureDoesNotEscapeReceiveThread() {
        val decoder = FakePlayoutDecoder(failing = true, failingClose = true)
        val failures = AtomicInteger()
        val clock = UDPAudioPlane.PlayoutClock(decoder, { fixedNow }, {}, { failures.incrementAndGet() })
        (1L..target(decoder)).forEach {
            clock.offer(SequencedEncodedAudioFrame(it, decoder.payload(1)), fixedNow)
        }
        clock.tick()
        clock.close()
        clock.close()
        assertEquals(1, failures.get())
        assertEquals(1, decoder.closeCount.get())
    }

    @Test
    fun gapIsConcealedWithSilence() {
        val decoder = FakePlayoutDecoder()
        val emitted = mutableListOf<ByteArray>()
        val failures = AtomicInteger()
        val clock = UDPAudioPlane.PlayoutClock(decoder, { fixedNow }, { emitted += it }, { failures.incrementAndGet() })
        try {
            // Fill the playout target with sequence `target + 1` missing, then one frame after the gap.
            val target = target(decoder)
            val offered = (1L..target) + (target + 2)
            offered.forEach { sequence ->
                assertEquals(
                    EncodedAudioFrameOfferResult.ACCEPTED,
                    clock.offer(SequencedEncodedAudioFrame(sequence, decoder.payload(sequence.toByte())), fixedNow),
                )
            }
            repeat(offered.size + 1) { clock.tick() }

            // 16 kHz * 20 ms / 1000 * 1 channel * 2 bytes = 640 bytes of PCM16 silence.
            assertEquals(640, clock.silenceFrame.size)
            assertEquals(offered.size + 1, emitted.size)
            (1L..target).forEachIndexed { index, sequence -> assertArrayEquals(byteArrayOf(sequence.toByte()), emitted[index]) }
            val silence = emitted[target.toInt()]
            assertEquals(640, silence.size)
            assertTrue(silence.all { it == 0.toByte() })
            assertArrayEquals(byteArrayOf((target + 2).toByte()), emitted.last())
            assertEquals(0, failures.get())
            assertEquals(offered.size, decoder.decodeCount.get())
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
            (1L..target(decoder)).forEach { sequence ->
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

private class FakePlayoutDecoder(private val failing: Boolean = false, private val failingClose: Boolean = false) : RealtimeAudioDecoderInterface {
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
        if (failingClose) throw IllegalStateException("codec stop rejected after decode failure")
    }
}

/** The shared playout target for the fake decoder's configuration (ADR-075). */
private fun target(decoder: RealtimeAudioDecoderInterface): Long =
    com.aessam.toursession.RealtimeAudioPlayoutSizing.frameCounts(decoder.configuration).first.toLong()
