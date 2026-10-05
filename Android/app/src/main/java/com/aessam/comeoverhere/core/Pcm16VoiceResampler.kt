package com.aessam.comeoverhere.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/** Streaming anti-aliased 48→16 kHz conversion for MediaCodec Opus output; mono PCM16 LE. */
internal class Pcm16VoiceResampler(val inputSampleRate: Int) {
    init { require(inputSampleRate == 16_000 || inputSampleRate == 48_000) { "Unsupported native PCM rate" } }

    private val history = DoubleArray(TAPS)
    private var position = 0
    private var phase = 0

    fun convert(pcm: ByteArray): ByteArray {
        require(pcm.size % 2 == 0) { "Native PCM16 has an incomplete sample" }
        if (inputSampleRate == 16_000) return pcm
        val output = ByteArray(((pcm.size / 2 + 2) / 3) * 2)
        var written = 0
        for (offset in pcm.indices step 2) {
            val sample = ((pcm[offset].toInt() and 0xff) or (pcm[offset + 1].toInt() shl 8)).toShort()
            history[position] = sample.toDouble()
            position = (position + 1) % TAPS
            phase++
            if (phase != 3) continue
            phase = 0
            var filtered = 0.0
            for (tap in 0 until TAPS) filtered += coefficients[tap] * history[(position - 1 - tap + TAPS) % TAPS]
            val value = filtered.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            output[written++] = value.toByte()
            output[written++] = (value shr 8).toByte()
        }
        return output.copyOf(written)
    }

    private companion object {
        const val TAPS = 63
        // Windowed-sinc low-pass at 7 kHz: reject frequencies above the 16 kHz Nyquist limit.
        val coefficients = DoubleArray(TAPS) { index ->
            val distance = index - (TAPS - 1) / 2
            val cutoff = 7_000.0 / 48_000
            val sinc = if (distance == 0) 2 * cutoff else sin(2 * PI * cutoff * distance) / (PI * distance)
            sinc * (0.54 - 0.46 * cos(2 * PI * index / (TAPS - 1)))
        }.let { taps -> val sum = taps.sum(); DoubleArray(TAPS) { taps[it] / sum } }
    }
}
