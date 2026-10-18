package com.aessam.toursession

enum class SessionCapability(val bit: Long) {
    OPUS_ENCODER(1L shl 0),
    OPUS_DECODER(1L shl 1),
    AAC_LC_ENCODER(1L shl 2),
    AAC_LC_DECODER(1L shl 3),
    /** The receiver accepts `audioBatch` envelopes. Opus is sent only in batches (ADR-075). */
    OPUS_BATCH_DECODER(1L shl 4),
    /** The guest can host its platform island as the cross-platform bridge (ADR-081 W2). */
    RELAY_HOST(1L shl 5),
}

enum class SessionAudioCodec(val rawValue: Int) {
    OPUS(1),
    AAC_LC(2);

    companion object {
        fun fromRaw(raw: Int): SessionAudioCodec = entries.firstOrNull { it.rawValue == raw }
            ?: throw EncodedAudioFrameException("unsupported audio codec $raw")
    }
}

class EncodedAudioFrameException(message: String) : IllegalArgumentException(message)

data class SessionAudioCodecConfiguration(
    val codec: SessionAudioCodec,
    val sampleRate: Long,
    val channelCount: Int,
    val frameDurationMilliseconds: Int,
    val bitRate: Long,
    val codecSpecificData: ByteArray = byteArrayOf(),
) {
    init {
        if (sampleRate !in 1..0xffff_ffffL) throw EncodedAudioFrameException("invalid audio sample rate $sampleRate")
        if (channelCount !in 1..0xff) throw EncodedAudioFrameException("invalid audio channel count $channelCount")
        if (frameDurationMilliseconds !in 1..0xffff) {
            throw EncodedAudioFrameException("invalid audio frame duration $frameDurationMilliseconds ms")
        }
        if (bitRate !in 1..0xffff_ffffL) throw EncodedAudioFrameException("invalid audio bit rate $bitRate")
        require(codecSpecificData.size.toLong() <= 0xffff_ffffL)
    }

    override fun equals(other: Any?): Boolean =
        other is SessionAudioCodecConfiguration &&
            codec == other.codec &&
            sampleRate == other.sampleRate &&
            channelCount == other.channelCount &&
            frameDurationMilliseconds == other.frameDurationMilliseconds &&
            bitRate == other.bitRate &&
            codecSpecificData.contentEquals(other.codecSpecificData)

    override fun hashCode(): Int = 31 * codec.hashCode() + codecSpecificData.contentHashCode()
}

class EncodedAudioFramePayload(
    val configuration: SessionAudioCodecConfiguration,
    val capturedAtNanoseconds: Long,
    val expiresAtNanoseconds: Long,
    val encodedBytes: ByteArray,
) {
    init {
        if (capturedAtNanoseconds < 0 || expiresAtNanoseconds <= capturedAtNanoseconds) {
            throw EncodedAudioFrameException(
                "audio expiry $expiresAtNanoseconds must be after capture $capturedAtNanoseconds",
            )
        }
    }

    fun isExpired(atNanoseconds: Long): Boolean = atNanoseconds >= expiresAtNanoseconds

    override fun equals(other: Any?): Boolean =
        other is EncodedAudioFramePayload &&
            configuration == other.configuration &&
            capturedAtNanoseconds == other.capturedAtNanoseconds &&
            expiresAtNanoseconds == other.expiresAtNanoseconds &&
            encodedBytes.contentEquals(other.encodedBytes)

    override fun hashCode(): Int = 31 * configuration.hashCode() + encodedBytes.contentHashCode()

    fun encode(): ByteArray {
        val writer = BinaryWriter(FIXED_HEADER_SIZE + encodedBytes.size)
        writer.appendUInt8(configuration.codec.rawValue)
        writer.appendUInt32(configuration.sampleRate)
        writer.appendUInt8(configuration.channelCount)
        writer.appendUInt16(configuration.frameDurationMilliseconds)
        writer.appendUInt32(configuration.bitRate)
        writer.appendUInt32(configuration.codecSpecificData.size.toLong())
        writer.append(configuration.codecSpecificData)
        writer.appendUInt64(capturedAtNanoseconds)
        writer.appendUInt64(expiresAtNanoseconds)
        writer.appendUInt32(encodedBytes.size.toLong())
        writer.append(encodedBytes)
        return writer.toByteArray()
    }

    companion object {
        const val FIXED_HEADER_SIZE = 36

        fun decode(data: ByteArray): EncodedAudioFramePayload {
            val reader = BinaryReader(data)
            val codec = SessionAudioCodec.fromRaw(reader.readUInt8())
            val sampleRate = reader.readUInt32()
            val channelCount = reader.readUInt8()
            val frameDuration = reader.readUInt16()
            val bitRate = reader.readUInt32()
            val codecSpecificData = reader.readBytes(reader.readUInt32().toInt())
            val configuration = SessionAudioCodecConfiguration(
                codec,
                sampleRate,
                channelCount,
                frameDuration,
                bitRate,
                codecSpecificData,
            )
            val capturedAt = reader.readUInt64()
            val expiresAt = reader.readUInt64()
            val payloadLength = reader.readUInt32().toInt()
            if (reader.remaining != payloadLength) {
                throw SessionProtocolException(
                    "payload length mismatch: expected $payloadLength, got ${reader.remaining}",
                )
            }
            return EncodedAudioFramePayload(
                configuration,
                capturedAt,
                expiresAt,
                reader.readBytes(payloadLength),
            )
        }
    }
}

object SessionAudioCodecNegotiation {
    fun preferredCodec(senderCapabilities: Long, receiverCapabilities: Long): SessionAudioCodec {
        if (
            // Opus travels only in batches; a receiver without batch support falls back to AAC-LC.
            senderCapabilities has SessionCapability.OPUS_ENCODER &&
            receiverCapabilities has SessionCapability.OPUS_DECODER &&
            receiverCapabilities has SessionCapability.OPUS_BATCH_DECODER
        ) {
            return SessionAudioCodec.OPUS
        }
        if (
            senderCapabilities has SessionCapability.AAC_LC_ENCODER &&
            receiverCapabilities has SessionCapability.AAC_LC_DECODER
        ) {
            return SessionAudioCodec.AAC_LC
        }
        throw EncodedAudioFrameException("sender and receiver have no common native audio codec")
    }

    private infix fun Long.has(capability: SessionCapability): Boolean = this and capability.bit != 0L
}

/**
 * Consecutive frames of one codec configuration sealed as one envelope (ADR-075). The configuration
 * is written once; each frame keeps its own capture and expiry time. The envelope sequence is the
 * first frame's sequence and frame `i` has sequence `first + i`.
 */
class EncodedAudioBatchPayload(frames: List<EncodedAudioFramePayload>) {
    val frames: List<EncodedAudioFramePayload> = frames.toList()

    init {
        if (this.frames.size !in 1..MAXIMUM_FRAME_COUNT) {
            throw EncodedAudioFrameException("invalid audio batch frame count ${this.frames.size}")
        }
        if (this.frames.any { it.configuration != this.frames[0].configuration }) {
            throw EncodedAudioFrameException("audio batch frames use different codec configurations")
        }
    }

    val configuration: SessionAudioCodecConfiguration get() = frames[0].configuration

    override fun equals(other: Any?): Boolean = other is EncodedAudioBatchPayload && frames == other.frames
    override fun hashCode(): Int = frames.hashCode()

    fun encode(): ByteArray {
        val writer = BinaryWriter(32 + frames.sumOf { 20 + it.encodedBytes.size })
        writer.appendUInt8(configuration.codec.rawValue)
        writer.appendUInt32(configuration.sampleRate)
        writer.appendUInt8(configuration.channelCount)
        writer.appendUInt16(configuration.frameDurationMilliseconds)
        writer.appendUInt32(configuration.bitRate)
        writer.appendUInt32(configuration.codecSpecificData.size.toLong())
        writer.append(configuration.codecSpecificData)
        writer.appendUInt8(frames.size)
        frames.forEach { frame ->
            writer.appendUInt64(frame.capturedAtNanoseconds)
            writer.appendUInt64(frame.expiresAtNanoseconds)
            writer.appendUInt32(frame.encodedBytes.size.toLong())
            writer.append(frame.encodedBytes)
        }
        return writer.toByteArray()
    }

    companion object {
        const val MAXIMUM_FRAME_COUNT = 8

        fun decode(data: ByteArray): EncodedAudioBatchPayload {
            val reader = BinaryReader(data)
            val codec = SessionAudioCodec.fromRaw(reader.readUInt8())
            val sampleRate = reader.readUInt32()
            val channelCount = reader.readUInt8()
            val frameDuration = reader.readUInt16()
            val bitRate = reader.readUInt32()
            val codecSpecificData = reader.readBytes(reader.readUInt32().toInt())
            val configuration = SessionAudioCodecConfiguration(codec, sampleRate, channelCount, frameDuration, bitRate, codecSpecificData)
            val count = reader.readUInt8()
            if (count !in 1..MAXIMUM_FRAME_COUNT) throw EncodedAudioFrameException("invalid audio batch frame count $count")
            val frames = (0 until count).map {
                val capturedAt = reader.readUInt64()
                val expiresAt = reader.readUInt64()
                val length = reader.readUInt32()
                if (length > reader.remaining.toLong()) {
                    throw SessionProtocolException("payload length mismatch: expected $length, got ${reader.remaining}")
                }
                EncodedAudioFramePayload(configuration, capturedAt, expiresAt, reader.readBytes(length.toInt()))
            }
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload length mismatch: expected 0, got ${reader.remaining}")
            }
            return EncodedAudioBatchPayload(frames)
        }
    }
}

data class SequencedEncodedAudioBatch(val firstSequence: Long, val payload: EncodedAudioBatchPayload) {
    /** The frames in playout order with their individual sequences. */
    val sequencedFrames: List<SequencedEncodedAudioFrame>
        get() = payload.frames.mapIndexed { index, frame -> SequencedEncodedAudioFrame(firstSequence + index, frame) }
}

/**
 * Groups consecutive sender frames into batches. A batch closes when it is full, when a frame is not
 * the next sequence or changes configuration, or when the first pending frame has waited
 * [maximumWaitNanoseconds] (the caller schedules [flushIfDue] at [flushDeadlineNanoseconds]).
 */
class AudioFrameBatcher(val maximumFrameCount: Int, val maximumWaitNanoseconds: Long) {
    private val pending = mutableListOf<EncodedAudioFramePayload>()
    private var firstSequence = 0L
    private var firstAppendedAtNanoseconds = 0L

    init {
        if (maximumFrameCount !in 1..EncodedAudioBatchPayload.MAXIMUM_FRAME_COUNT) {
            throw EncodedAudioFrameException("invalid audio batch frame count $maximumFrameCount")
        }
        require(maximumWaitNanoseconds >= 0)
    }

    val pendingFrameCount: Int get() = pending.size

    val flushDeadlineNanoseconds: Long?
        get() = if (pending.isEmpty()) null else try {
            Math.addExact(firstAppendedAtNanoseconds, maximumWaitNanoseconds)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }

    fun append(frame: SequencedEncodedAudioFrame, nowNanoseconds: Long): List<SequencedEncodedAudioBatch> {
        val batches = mutableListOf<SequencedEncodedAudioBatch>()
        if (pending.isNotEmpty()) {
            val next = try { Math.addExact(firstSequence, pending.size.toLong()) } catch (_: ArithmeticException) { null }
            if (next == null || frame.sequence != next || frame.payload.configuration != pending[0].configuration) {
                flushAll()?.let(batches::add)
            }
        }
        if (pending.isEmpty()) {
            firstSequence = frame.sequence
            firstAppendedAtNanoseconds = nowNanoseconds
        }
        pending += frame.payload
        if (pending.size == maximumFrameCount) flushAll()?.let(batches::add)
        return batches
    }

    fun flushIfDue(nowNanoseconds: Long): SequencedEncodedAudioBatch? {
        val deadline = flushDeadlineNanoseconds ?: return null
        return if (nowNanoseconds >= deadline) flushAll() else null
    }

    fun flushAll(): SequencedEncodedAudioBatch? {
        if (pending.isEmpty()) return null
        val batch = SequencedEncodedAudioBatch(firstSequence, EncodedAudioBatchPayload(pending.toList()))
        pending.clear()
        return batch
    }

    /** Drops pending frames, for capture discontinuities and stop. */
    fun discard() = pending.clear()
}
