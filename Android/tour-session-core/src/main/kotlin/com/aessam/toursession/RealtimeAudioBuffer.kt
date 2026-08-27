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

class EncodedAudioJitterBuffer(
    val targetFrameCount: Int,
    val maximumFrameCount: Int,
) {
    private val frames = sortedMapOf<Long, EncodedAudioFramePayload>()
    private var expectedSequence: Long? = null
    private var hasStarted = false

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
        if (frame.payload.isExpired(nowNanoseconds)) return EncodedAudioFrameOfferResult.EXPIRED
        if (frames.containsKey(frame.sequence)) return EncodedAudioFrameOfferResult.DUPLICATE
        val expected = expectedSequence
        if (hasStarted && expected != null && frame.sequence < expected) {
            return EncodedAudioFrameOfferResult.DUPLICATE
        }
        if (frames.size >= maximumFrameCount) return EncodedAudioFrameOfferResult.CAPACITY_EXCEEDED

        frames[frame.sequence] = frame.payload
        if (!hasStarted && (expected == null || frame.sequence < expected)) {
            expectedSequence = frame.sequence
        }
        return EncodedAudioFrameOfferResult.ACCEPTED
    }

    fun popReady(nowNanoseconds: Long): SequencedEncodedAudioFrame? {
        frames.entries.removeAll { (_, payload) -> payload.isExpired(nowNanoseconds) }
        if (frames.isEmpty()) return null

        if (!hasStarted) {
            if (frames.size < targetFrameCount) return null
            hasStarted = true
            expectedSequence = frames.firstKey()
        }

        var sequence = expectedSequence ?: return null
        if (!frames.containsKey(sequence)) {
            if (frames.size < targetFrameCount) return null
            sequence = frames.firstKey()
        }
        val payload = frames.remove(sequence) ?: return null
        expectedSequence = if (sequence == Long.MAX_VALUE) null else sequence + 1
        return SequencedEncodedAudioFrame(sequence, payload)
    }

    fun reset() {
        frames.clear()
        expectedSequence = null
        hasStarted = false
    }
}
