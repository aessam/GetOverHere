package com.aessam.comeoverhere.core

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import com.aessam.comeoverhere.service.NativeAudioCodecCapabilities
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionCapability
import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.ByteOrder

class NativeRealtimeAudioCodecException(message: String) : IllegalStateException(message)

data class NativeEncodedAudioPacket(
    val configuration: SessionAudioCodecConfiguration,
    val bytes: ByteArray,
)

interface RealtimeAudioEncoderInterface : Closeable {
    val codec: SessionAudioCodec
    val inputPCMByteCount: Int
    fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket?
}

interface RealtimeAudioDecoderInterface : Closeable {
    val configuration: SessionAudioCodecConfiguration
    fun decode(packet: ByteArray): ByteArray?
}

interface RealtimeAudioCodecProvider {
    fun sessionCapabilities(): Long
    fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface
    fun makeDecoder(configuration: SessionAudioCodecConfiguration): RealtimeAudioDecoderInterface
}

object NativeRealtimeAudioCodecFactory : RealtimeAudioCodecProvider {
    override fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface =
        AndroidNativeRealtimeAudioEncoder(codec)

    override fun makeDecoder(configuration: SessionAudioCodecConfiguration): RealtimeAudioDecoderInterface =
        AndroidNativeRealtimeAudioDecoder(configuration)

    override fun sessionCapabilities(): Long {
        val native = NativeAudioCodecCapabilities.current()
        var result = 0L
        if (native.opusEncoder != null) result = result or SessionCapability.OPUS_ENCODER.bit
        if (native.opusDecoder != null) result = result or SessionCapability.OPUS_DECODER.bit
        if (native.aacLCEncoder != null) result = result or SessionCapability.AAC_LC_ENCODER.bit
        if (native.aacLCDecoder != null) result = result or SessionCapability.AAC_LC_DECODER.bit
        return result
    }
}

private data class NativeCodecParameters(
    val mimeType: String,
    val sampleRate: Int,
    val channelCount: Int,
    val frameDurationMilliseconds: Int,
    val bitRate: Int,
    val frameSampleCount: Int,
)

private class AndroidNativeRealtimeAudioEncoder(
    override val codec: SessionAudioCodec,
) : RealtimeAudioEncoderInterface {
    private val parameters = parameters(codec)
    private val mediaCodec: MediaCodec
    private val bufferInfo = MediaCodec.BufferInfo()
    private var codecSpecificData = byteArrayOf()
    private var presentationTimeUs = 0L
    private var closed = false

    override val inputPCMByteCount: Int = parameters.frameSampleCount * parameters.channelCount * Short.SIZE_BYTES

    init {
        val format = encoderFormat(parameters, codec)
        val codecName = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw NativeRealtimeAudioCodecException("native encoder is unavailable: $codec")
        mediaCodec = MediaCodec.createByCodecName(codecName)
        mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        mediaCodec.start()
    }

    @Synchronized
    override fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket? {
        check(!closed) { "native encoder is closed" }
        if (pcm16LittleEndian.size != inputPCMByteCount) {
            throw NativeRealtimeAudioCodecException(
                "PCM frame has ${pcm16LittleEndian.size} bytes; expected $inputPCMByteCount",
            )
        }
        val inputIndex = mediaCodec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
        if (inputIndex < 0) return null
        val input = mediaCodec.getInputBuffer(inputIndex)
            ?: throw NativeRealtimeAudioCodecException("native encoder input buffer is unavailable")
        input.clear()
        input.put(pcm16LittleEndian)
        mediaCodec.queueInputBuffer(inputIndex, 0, pcm16LittleEndian.size, presentationTimeUs, 0)
        presentationTimeUs += parameters.frameDurationMilliseconds * 1_000L

        repeat(MAX_DRAIN_ATTEMPTS) {
            when (val outputIndex = mediaCodec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return null
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> captureCodecSpecificData(mediaCodec.outputFormat)
                else -> if (outputIndex >= 0) {
                    val output = mediaCodec.getOutputBuffer(outputIndex)
                        ?: throw NativeRealtimeAudioCodecException("native encoder output buffer is unavailable")
                    val bytes = output.copyBytes(bufferInfo.offset, bufferInfo.size)
                    val codecConfig = bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    mediaCodec.releaseOutputBuffer(outputIndex, false)
                    if (codecConfig) {
                        if (bytes.isNotEmpty()) codecSpecificData = bytes
                    } else if (bytes.isNotEmpty()) {
                        return NativeEncodedAudioPacket(
                            SessionAudioCodecConfiguration(
                                codec,
                                parameters.sampleRate.toLong(),
                                parameters.channelCount,
                                parameters.frameDurationMilliseconds,
                                parameters.bitRate.toLong(),
                                codecSpecificData.copyOf(),
                            ),
                            bytes,
                        )
                    }
                }
            }
        }
        return null
    }

    private fun captureCodecSpecificData(format: MediaFormat) {
        codecSpecificData = format.getByteBuffer("csd-0")?.copyRemainingBytes() ?: codecSpecificData
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        // release is valid in the error state; stop can mask the original codec failure.
        mediaCodec.release()
    }
}

private class AndroidNativeRealtimeAudioDecoder(
    override val configuration: SessionAudioCodecConfiguration,
) : RealtimeAudioDecoderInterface {
    private val mediaCodec: MediaCodec
    private val bufferInfo = MediaCodec.BufferInfo()
    private var presentationTimeUs = 0L
    private var closed = false
    private var pcmConverter: Pcm16VoiceResampler? = null

    init {
        val format = MediaFormat.createAudioFormat(
            mimeType(configuration.codec),
            configuration.sampleRate.toInt(),
            configuration.channelCount,
        ).apply {
            setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            if (configuration.codec == SessionAudioCodec.AAC_LC) {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            }
            // GOH voice profiles already specify the decoder parameters. Apple's magic cookie
            // is not Android CSD. Build the documented Android initialization for these profiles
            // instead of forwarding an opaque, platform-specific encoder cookie.
            require(configuration.sampleRate == 16_000L && configuration.channelCount == 1) {
                "Native voice decoding requires 16 kHz mono"
            }
            when (configuration.codec) {
                SessionAudioCodec.OPUS -> {
                    val header = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
                        .put("OpusHead".toByteArray(Charsets.US_ASCII)).put(1).put(1)
                        .putShort(0).putInt(16_000).putShort(0).put(0).array()
                    setByteBuffer("csd-0", ByteBuffer.wrap(header))
                    // Live guests may join midstream: no file-start pre-skip is appropriate.
                    setByteBuffer("csd-1", ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).apply { putLong(0); flip() })
                    setByteBuffer("csd-2", ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).apply { putLong(80_000_000); flip() })
                }
                SessionAudioCodec.AAC_LC -> {
                    // MPEG-4 AudioSpecificConfig: AAC-LC (2), 16 kHz (8), mono (1).
                    setByteBuffer("csd-0", ByteBuffer.wrap(byteArrayOf(0x14, 0x08)))
                }
            }
        }
        val codecName = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
            ?: throw NativeRealtimeAudioCodecException("native decoder is unavailable: ${configuration.codec}")
        mediaCodec = MediaCodec.createByCodecName(codecName)
        mediaCodec.configure(format, null, null, 0)
        mediaCodec.start()
    }

    @Synchronized
    override fun decode(packet: ByteArray): ByteArray? {
        check(!closed) { "native decoder is closed" }
        if (packet.isEmpty()) throw NativeRealtimeAudioCodecException("encoded packet is empty")
        val inputIndex = mediaCodec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
        if (inputIndex < 0) return null
        val input = mediaCodec.getInputBuffer(inputIndex)
            ?: throw NativeRealtimeAudioCodecException("native decoder input buffer is unavailable")
        input.clear()
        input.put(packet)
        mediaCodec.queueInputBuffer(inputIndex, 0, packet.size, presentationTimeUs, 0)
        presentationTimeUs += configuration.frameDurationMilliseconds * 1_000L

        repeat(MAX_DRAIN_ATTEMPTS) {
            when (val outputIndex = mediaCodec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return null
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> configurePCMOutput(mediaCodec.outputFormat)
                else -> if (outputIndex >= 0) {
                    val output = mediaCodec.getOutputBuffer(outputIndex)
                        ?: throw NativeRealtimeAudioCodecException("native decoder output buffer is unavailable")
                    val bytes = output.copyBytes(bufferInfo.offset, bufferInfo.size)
                    mediaCodec.releaseOutputBuffer(outputIndex, false)
                    if (bytes.isNotEmpty()) {
                        if (pcmConverter == null) configurePCMOutput(mediaCodec.outputFormat)
                        return requireNotNull(pcmConverter).convert(bytes).takeIf { it.isNotEmpty() }
                    }
                }
            }
        }
        return null
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        mediaCodec.release()
    }

    private fun configurePCMOutput(format: MediaFormat) {
        require(format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 1) { "Native decoder did not produce mono" }
        if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            require(format.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_16BIT) {
                "Native decoder did not produce PCM16"
            }
        }
        val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        if (pcmConverter?.inputSampleRate != rate) pcmConverter = Pcm16VoiceResampler(rate)
    }
}

private fun parameters(codec: SessionAudioCodec): NativeCodecParameters = when (codec) {
    SessionAudioCodec.OPUS -> NativeCodecParameters(
        MediaFormat.MIMETYPE_AUDIO_OPUS,
        16_000,
        1,
        20,
        20_000,
        320,
    )
    SessionAudioCodec.AAC_LC -> NativeCodecParameters(
        MediaFormat.MIMETYPE_AUDIO_AAC,
        16_000,
        1,
        64,
        16_000,
        1_024,
    )
}

private fun encoderFormat(parameters: NativeCodecParameters, codec: SessionAudioCodec): MediaFormat =
    MediaFormat.createAudioFormat(parameters.mimeType, parameters.sampleRate, parameters.channelCount).apply {
        setInteger(MediaFormat.KEY_BIT_RATE, parameters.bitRate)
        setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        if (codec == SessionAudioCodec.AAC_LC) {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        }
    }

private fun mimeType(codec: SessionAudioCodec): String = when (codec) {
    SessionAudioCodec.OPUS -> MediaFormat.MIMETYPE_AUDIO_OPUS
    SessionAudioCodec.AAC_LC -> MediaFormat.MIMETYPE_AUDIO_AAC
}

private fun ByteBuffer.copyRemainingBytes(): ByteArray = duplicate().let { copy ->
    ByteArray(copy.remaining()).also(copy::get)
}

private fun ByteBuffer.copyBytes(offset: Int, size: Int): ByteArray {
    if (size <= 0) return byteArrayOf()
    val copy = duplicate()
    copy.position(offset)
    copy.limit(offset + size)
    return ByteArray(size).also(copy::get)
}

private const val DEQUEUE_TIMEOUT_US = 10_000L
private const val MAX_DRAIN_ATTEMPTS = 8
