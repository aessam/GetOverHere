package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors AudioBatchTests.swift (ADR-075); the pinned hex must stay identical on both platforms. */
class AudioBatchTest {
    private val batchHex = "0100003e8001001400004e20000000044f70757303000000003b9aca000000000059682f0000000004f8fffe00000000003ccbf700000000005a995c0000000004f8fffe01000000003dfd2400000000005bca890000000004f8fffe02"

    private fun opus(csd: ByteArray = byteArrayOf()) = SessionAudioCodecConfiguration(SessionAudioCodec.OPUS, 16_000, 1, 20, 20_000, csd)

    private fun frame(sequence: Long, configuration: SessionAudioCodecConfiguration = opus(), bytes: Int = 4): SequencedEncodedAudioFrame {
        val captured = 1_000_000_000L + sequence * 20_000_000L
        return SequencedEncodedAudioFrame(sequence, EncodedAudioFramePayload(configuration, captured, captured + 500_000_000L, ByteArray(bytes) { sequence.toByte() }))
    }

    @Test fun batchFixtureBytesArePinnedAndRoundTrip() {
        val fixture = TourSessionFixtures.encodedAudioBatchFixture()
        assertEquals(batchHex, fixture.encode().lowercaseHex())
        assertEquals(fixture, EncodedAudioBatchPayload.decode(batchHex.hexToByteArray()))
        assertEquals(0x11, SessionMessageKind.AUDIO_BATCH.rawValue)
        assertEquals(SessionLane.REALTIME, SessionMessageKind.AUDIO_BATCH.requiredLane)
        assertEquals(1L shl 4, SessionCapability.OPUS_BATCH_DECODER.bit)
    }

    @Test fun malformedBatchesAreRejected() {
        val bytes = batchHex.hexToByteArray()
        val countOffset = 1 + 4 + 1 + 2 + 4 + 4 + 4
        assertEquals(3, bytes[countOffset].toInt())
        for (invalid in listOf(0, 9)) {
            val copy = bytes.copyOf().also { it[countOffset] = invalid.toByte() }
            val error = assertThrows(EncodedAudioFrameException::class.java) { EncodedAudioBatchPayload.decode(copy) }
            assertEquals("invalid audio batch frame count $invalid", error.message)
        }
        assertThrows(SessionProtocolException::class.java) { EncodedAudioBatchPayload.decode(bytes + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { EncodedAudioBatchPayload.decode(bytes.copyOf(bytes.size - 1)) }
        val mismatch = assertThrows(EncodedAudioFrameException::class.java) {
            EncodedAudioBatchPayload(listOf(frame(0).payload, frame(1, opus(byteArrayOf(1))).payload))
        }
        assertEquals("audio batch frames use different codec configurations", mismatch.message)
        assertThrows(EncodedAudioFrameException::class.java) { EncodedAudioBatchPayload(emptyList()) }
    }

    @Test fun batcherClosesOnCountGapConfigurationDeadlineAndDiscard() {
        val batcher = AudioFrameBatcher(3, 40)
        assertTrue(batcher.append(frame(10), 100).isEmpty())
        assertTrue(batcher.append(frame(11), 120).isEmpty())
        val full = batcher.append(frame(12), 130)
        assertEquals(listOf(10L), full.map { it.firstSequence })
        assertEquals(listOf(10L, 11L, 12L), full[0].sequencedFrames.map { it.sequence })
        assertNull(batcher.flushDeadlineNanoseconds)

        assertTrue(batcher.append(frame(13), 200).isEmpty())
        val gap = batcher.append(frame(15), 210)
        assertEquals(listOf(13L), gap.map { it.firstSequence })
        assertEquals(1, gap[0].payload.frames.size)
        assertEquals(listOf(15L), batcher.append(frame(16, opus(byteArrayOf(7))), 215).map { it.firstSequence })

        assertEquals(255L, batcher.flushDeadlineNanoseconds)
        assertNull(batcher.flushIfDue(254))
        assertEquals(16L, batcher.flushIfDue(255)?.firstSequence)

        batcher.append(frame(17), 300)
        batcher.discard()
        assertNull(batcher.flushAll())
        assertThrows(EncodedAudioFrameException::class.java) { AudioFrameBatcher(9, 0) }
    }

    @Test fun opusIsNegotiatedOnlyWithBatchSupport() {
        val sender = SessionCapability.OPUS_ENCODER.bit or SessionCapability.AAC_LC_ENCODER.bit
        val batched = SessionCapability.OPUS_DECODER.bit or SessionCapability.OPUS_BATCH_DECODER.bit or SessionCapability.AAC_LC_DECODER.bit
        assertEquals(SessionAudioCodec.OPUS, SessionAudioCodecNegotiation.preferredCodec(sender, batched))
        assertEquals(SessionAudioCodec.AAC_LC, SessionAudioCodecNegotiation.preferredCodec(sender, SessionCapability.OPUS_DECODER.bit or SessionCapability.AAC_LC_DECODER.bit))
        assertThrows(EncodedAudioFrameException::class.java) {
            SessionAudioCodecNegotiation.preferredCodec(sender, SessionCapability.OPUS_DECODER.bit)
        }
    }

    @Test fun threeFramesSealedAsOneBatchCostAtMost55PercentOfSingles() {
        val credential = TourSessionFixtures.fixtureCredential()
        val configuration = opus(ByteArray(19) { 0x4f })
        val frames = (0L until 3L).map { frame(it, configuration, 50) }
        val perPacket = 4 + 8 + 64 // length prefix + GOS1 header + signature
        val stream = UUID.randomUUID()
        val sealer = SessionFrameSealer(credential)
        val singles = frames.sumOf { frame ->
            sealer.seal(SessionEnvelope(lane = SessionLane.REALTIME, kind = SessionMessageKind.AUDIO_FRAME, sequence = frame.sequence,
                sessionId = TourSessionFixtures.sessionId, senderId = TourSessionFixtures.guideId, payload = frame.payload.encode()), stream).encode().size + perPacket
        }
        val batch = SessionFrameSealer(credential).seal(SessionEnvelope(lane = SessionLane.REALTIME, kind = SessionMessageKind.AUDIO_BATCH, sequence = 0,
            sessionId = TourSessionFixtures.sessionId, senderId = TourSessionFixtures.guideId,
            payload = EncodedAudioBatchPayload(frames.map { it.payload }).encode()), stream).encode().size + perPacket
        assertTrue("batch $batch B vs singles $singles B", batch <= 0.55 * singles)
    }

    @Test fun playoutSizingCoversTwoOpusBursts() {
        assertEquals(6 to 13, RealtimeAudioPlayoutSizing.frameCounts(opus()))
        assertEquals(1 to 4, RealtimeAudioPlayoutSizing.frameCounts(SessionAudioCodecConfiguration(SessionAudioCodec.AAC_LC, 16_000, 1, 64, 16_000)))
    }

    private fun stallsAfterWarmUp(target: Int, maximum: Int, jitterScale: Long): Int {
        val buffer = EncodedAudioJitterBuffer(target, maximum)
        val jitter = longArrayOf(0, 6, -4, 9, 2, -6, 8, 0)
        val arrivals = (0 until 200).flatMap { batch ->
            val lastCapture = 1_000_000_000L + (batch * 3 + 2) * 20_000_000L
            val at = lastCapture + 10_000_000L + jitter[batch % jitter.size] * jitterScale * 1_000_000L
            (0 until 3).map { at to frame((batch * 3 + it).toLong(), bytes = 1) }
        }
        var next = 0
        var started = false
        var stalls = 0
        var now = 1_000_000_000L + 7_000_000L
        while (now < 1_000_000_000L + 11_000_000_000L) {
            while (next < arrivals.size && arrivals[next].first <= now) {
                buffer.offer(arrivals[next].second, arrivals[next].first)
                next++
            }
            when (buffer.popForPlayout(now)) {
                is EncodedAudioPlayoutDecision.Frame -> started = true
                else -> if (started) stalls++
            }
            now += 20_000_000L
        }
        return stalls
    }

    @Test fun burstArrivalPlaysWithoutStallsAtTheBatchedTarget() {
        val (target, maximum) = RealtimeAudioPlayoutSizing.frameCounts(opus())
        // Jitter peaks of 9-45 ms bracket the measured Bluetooth idle RTT spread (p95 - p50, Sept 10).
        for (scale in 1L..5L) assertEquals("scale $scale", 0, stallsAfterWarmUp(target, maximum, scale))
        assertTrue(stallsAfterWarmUp(3, 13, 2) > 0)
    }
}
