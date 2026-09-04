package com.aessam.toursession

class RealtimeAudioBufferException(message: String) : IllegalArgumentException(message)

class PCMFrameAccumulator(val frameByteCount: Int) {
    private var bufferedBytes = byteArrayOf()

    init {
        if (frameByteCount <= 0) {
            throw RealtimeAudioBufferException("frame byte count must be positive: $frameByteCount")
        }
    }

    val bufferedByteCount: Int
        get() = bufferedBytes.size

    fun append(bytes: ByteArray): List<ByteArray> {
        if (bytes.isEmpty()) return emptyList()
        bufferedBytes += bytes

        val frameCount = bufferedBytes.size / frameByteCount
        if (frameCount == 0) return emptyList()
        val frames = List(frameCount) { index ->
            val offset = index * frameByteCount
            bufferedBytes.copyOfRange(offset, offset + frameByteCount)
        }
        bufferedBytes = bufferedBytes.copyOfRange(frameCount * frameByteCount, bufferedBytes.size)
        return frames
    }

    fun reset() {
        bufferedBytes = byteArrayOf()
    }
}

data class SequencedEncodedAudioFrame(
    val sequence: Long,
    val payload: EncodedAudioFramePayload,
)

enum class EncodedAudioFrameOfferResult {
    ACCEPTED,
    DUPLICATE,
    EXPIRED,
    CAPACITY_EXCEEDED,
}

/**
 * One clock tick's playout decision (ADR-045): a playable frame, a single lost
 * sequence to conceal with one silence frame, or nothing to play yet.
 */
sealed class EncodedAudioPlayoutDecision {
    data class Frame(val frame: SequencedEncodedAudioFrame) : EncodedAudioPlayoutDecision()
    data class Conceal(val missingSequence: Long) : EncodedAudioPlayoutDecision()
    data object Wait : EncodedAudioPlayoutDecision()
}

class EncodedAudioJitterBuffer(
    val targetFrameCount: Int,
    val maximumFrameCount: Int,
) {
    private data class BufferedFrame(
        val payload: EncodedAudioFramePayload,
        val localDeadlineNanoseconds: Long,
    )

    private val frames = sortedMapOf<Long, BufferedFrame>()
    private var expectedSequence: Long? = null
    private var hasStarted = false
    private var minimumClockOffsetNanoseconds: Long? = null

    init {
        if (targetFrameCount <= 0 || maximumFrameCount < targetFrameCount) {
            throw RealtimeAudioBufferException(
                "invalid frame capacity: target=$targetFrameCount, maximum=$maximumFrameCount",
            )
        }
    }

    val bufferedFrameCount: Int
        get() = frames.size

    fun offer(frame: SequencedEncodedAudioFrame, nowNanoseconds: Long): EncodedAudioFrameOfferResult {
        if (frames.containsKey(frame.sequence)) return EncodedAudioFrameOfferResult.DUPLICATE
        val expected = expectedSequence
        if (hasStarted && expected != null && frame.sequence < expected) {
            return EncodedAudioFrameOfferResult.DUPLICATE
        }
        val deadline = localDeadline(frame.payload, nowNanoseconds)
            ?: return EncodedAudioFrameOfferResult.EXPIRED
        if (frames.size >= maximumFrameCount) return EncodedAudioFrameOfferResult.CAPACITY_EXCEEDED

        frames[frame.sequence] = BufferedFrame(frame.payload, deadline)
        if (!hasStarted && (expected == null || frame.sequence < expected)) {
            expectedSequence = frame.sequence
        }
        return EncodedAudioFrameOfferResult.ACCEPTED
    }

    /**
     * Clock-driven drain. Called once per negotiated frame duration by the playout timer.
     * A missing expected sequence while the buffer is below the target depth is concealed
     * (one silence frame keeps the timeline); at or above the target depth the buffer resyncs
     * to its oldest frame instead of waiting for a frame that is probably lost.
     */
    fun popForPlayout(nowNanoseconds: Long): EncodedAudioPlayoutDecision {
        frames.entries.removeAll { (_, frame) -> frame.localDeadlineNanoseconds <= nowNanoseconds }
        if (frames.isEmpty()) return EncodedAudioPlayoutDecision.Wait

        if (!hasStarted) {
            if (frames.size < targetFrameCount) return EncodedAudioPlayoutDecision.Wait
            hasStarted = true
            expectedSequence = frames.firstKey()
        }

        val sequence = expectedSequence ?: return EncodedAudioPlayoutDecision.Wait
        frames.remove(sequence)?.let { buffered ->
            expectedSequence = if (sequence == Long.MAX_VALUE) null else sequence + 1
            return EncodedAudioPlayoutDecision.Frame(SequencedEncodedAudioFrame(sequence, buffered.payload))
        }
        if (frames.size >= targetFrameCount) {
            val next = frames.firstKey()
            val buffered = frames.remove(next)
            if (buffered != null) {
                expectedSequence = if (next == Long.MAX_VALUE) null else next + 1
                return EncodedAudioPlayoutDecision.Frame(SequencedEncodedAudioFrame(next, buffered.payload))
            }
        }
        expectedSequence = if (sequence == Long.MAX_VALUE) null else sequence + 1
        return EncodedAudioPlayoutDecision.Conceal(sequence)
    }

    fun reset() {
        frames.clear()
        expectedSequence = null
        hasStarted = false
        minimumClockOffsetNanoseconds = null
    }

    /**
     * Maps the sender's monotonic capture timeline to receiver-local time.
     * Delay above the minimum observed clock offset consumes frame lifetime.
     */
    private fun localDeadline(payload: EncodedAudioFramePayload, receivedAtNanoseconds: Long): Long? {
        if (receivedAtNanoseconds < 0L) return null
        val observedOffset = try {
            Math.subtractExact(receivedAtNanoseconds, payload.capturedAtNanoseconds)
        } catch (_: ArithmeticException) {
            return null
        }
        val baseline = minOf(minimumClockOffsetNanoseconds ?: observedOffset, observedOffset)
        minimumClockOffsetNanoseconds = baseline
        val excessDelay = try {
            Math.subtractExact(observedOffset, baseline)
        } catch (_: ArithmeticException) {
            return null
        }
        val lifetime = payload.expiresAtNanoseconds - payload.capturedAtNanoseconds
        if (excessDelay < 0L || excessDelay >= lifetime) return null
        val remaining = lifetime - excessDelay
        return try {
            Math.addExact(receivedAtNanoseconds, remaining)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
    }
}
