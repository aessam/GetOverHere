package com.aessam.comeoverhere.service

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

data class NativeAudioCodecCapabilities(
    val sdkInt: Int,
    val opusEncoder: String?,
    val opusDecoder: String?,
    val aacLCEncoder: String?,
    val aacLCDecoder: String?,
) {
    companion object {
        private const val SAMPLE_RATE = 16_000
        private const val CHANNEL_COUNT = 1
        private const val OPUS_BIT_RATE = 20_000
        private const val AAC_LC_BIT_RATE = 16_000

        fun current(codecList: MediaCodecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)): NativeAudioCodecCapabilities {
            val opusEncoderFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_OPUS,
                SAMPLE_RATE,
                CHANNEL_COUNT,
            ).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, OPUS_BIT_RATE)
            }
            val opusDecoderFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_OPUS,
                SAMPLE_RATE,
                CHANNEL_COUNT,
            )
            val aacEncoderFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                SAMPLE_RATE,
                CHANNEL_COUNT,
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AAC_LC_BIT_RATE)
            }
            val aacDecoderFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                SAMPLE_RATE,
                CHANNEL_COUNT,
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            }

            return NativeAudioCodecCapabilities(
                sdkInt = Build.VERSION.SDK_INT,
                opusEncoder = codecList.findEncoderForFormat(opusEncoderFormat),
                opusDecoder = codecList.findDecoderForFormat(opusDecoderFormat),
                aacLCEncoder = codecList.findEncoderForFormat(aacEncoderFormat),
                aacLCDecoder = codecList.findDecoderForFormat(aacDecoderFormat),
            )
        }
    }
}
