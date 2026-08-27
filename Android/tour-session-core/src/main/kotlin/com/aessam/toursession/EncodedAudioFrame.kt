package com.aessam.toursession

enum class SessionCapability(val bit: Long) {
    OPUS_ENCODER(1L shl 0),
    OPUS_DECODER(1L shl 1),
    AAC_LC_ENCODER(1L shl 2),
    AAC_LC_DECODER(1L shl 3),
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
            senderCapabilities has SessionCapability.OPUS_ENCODER &&
            receiverCapabilities has SessionCapability.OPUS_DECODER
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
