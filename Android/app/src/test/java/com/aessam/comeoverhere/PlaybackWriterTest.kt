package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.PcmPlaybackSink
import com.aessam.comeoverhere.service.PlaybackWriteOutcome
import com.aessam.comeoverhere.service.PlaybackWriter
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `AudioTrack` cannot be built on the JVM (`Builder().build()` returns null under
 * `isReturnDefaultValues`), so the write loop over an injected sink is the testable unit (FND-5).
 */
class PlaybackWriterTest {
    private val frame = ByteArray(640) { it.toByte() }

    @Test
    fun fullWriteIsWritten() {
        val calls = mutableListOf<Pair<Int, Int>>()
        val sink = PcmPlaybackSink { _, offset, size ->
            calls += offset to size
            size
        }
        assertEquals(PlaybackWriteOutcome.Written, PlaybackWriter.write(sink, frame))
        assertEquals(listOf(0 to 640), calls)
    }

    @Test
    fun zeroWriteIsShort() {
        val sink = PcmPlaybackSink { _, _, _ -> 0 }
        assertEquals(PlaybackWriteOutcome.Short(0, 640), PlaybackWriter.write(sink, frame))
    }

    @Test
    fun partialThenZeroIsShortWithProgress() {
        val calls = mutableListOf<Pair<Int, Int>>()
        var call = 0
        val sink = PcmPlaybackSink { _, offset, size ->
            calls += offset to size
            if (call++ == 0) 100 else 0
        }
        assertEquals(PlaybackWriteOutcome.Short(100, 640), PlaybackWriter.write(sink, frame))
        assertEquals(listOf(0 to 640, 100 to 540), calls)
    }

    @Test
    fun negativeCodeIsFailed() {
        var calls = 0
        val sink = PcmPlaybackSink { _, _, _ ->
            calls++
            -6 // AudioTrack.ERROR_DEAD_OBJECT
        }
        assertEquals(PlaybackWriteOutcome.Failed(-6), PlaybackWriter.write(sink, frame))
        assertEquals(1, calls)
    }
}
