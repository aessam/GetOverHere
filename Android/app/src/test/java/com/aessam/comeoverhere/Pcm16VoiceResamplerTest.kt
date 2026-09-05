package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.Pcm16VoiceResampler
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class Pcm16VoiceResamplerTest {
    @Test fun streamingChunksMatchWholeSignalExactly() {
        val input = tone(440.0)
        val expected = Pcm16VoiceResampler(48_000).convert(input)
        val converter = Pcm16VoiceResampler(48_000)
        val output = java.io.ByteArrayOutputStream()
        // Deliberately split across the decimator's three-sample boundaries.
        input.toList().chunked(202).forEach { output.write(converter.convert(it.toByteArray())) }
        assertEquals(input.size / 3, expected.size)
        assertArrayEquals(expected, output.toByteArray())
    }

    @Test fun preservesVoiceFrequencyAndRejectsAliasing() {
        val low = samples(Pcm16VoiceResampler(48_000).convert(tone(440.0)))
        val high = samples(Pcm16VoiceResampler(48_000).convert(tone(10_000.0)))
        // Exclude the FIR's startup transient when measuring steady-state frequency.
        val settled = low.drop(64)
        val crossings = settled.zipWithNext().count { (left, right) -> left <= 0 && right > 0 }
        val expectedCrossings = settled.size * 440.0 / 16_000
        assertTrue("440 Hz changed frequency: $crossings crossings", kotlin.math.abs(crossings - expectedCrossings) <= 1)
        assertTrue("Voice attenuated", rms(low.drop(64)) > 5_000)
        assertTrue("Out-of-band tone aliased into voice", rms(high.drop(64)) < 40)
    }

    @Test fun passes16kAndRejectsInvalidInput() {
        val input = byteArrayOf(1, 2, 3, 4)
        assertArrayEquals(input, Pcm16VoiceResampler(16_000).convert(input))
        assertThrows(IllegalArgumentException::class.java) { Pcm16VoiceResampler(44_100) }
        assertThrows(IllegalArgumentException::class.java) { Pcm16VoiceResampler(48_000).convert(byteArrayOf(1)) }
    }

    private fun tone(frequency: Double): ByteArray = ByteBuffer.allocate(48_000 * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
        repeat(48_000) { putShort((sin(it * frequency * 2 * PI / 48_000) * 8_000).toInt().toShort()) }
    }.array()
    private fun samples(bytes: ByteArray): List<Int> = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).let { buffer ->
        List(bytes.size / 2) { buffer.short.toInt() }
    }
    private fun rms(samples: List<Int>): Double = sqrt(samples.sumOf { it.toDouble() * it } / samples.size)
}
