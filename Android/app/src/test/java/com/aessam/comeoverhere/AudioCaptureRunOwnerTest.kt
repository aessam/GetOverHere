package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.AudioCaptureRunOwner
import com.aessam.comeoverhere.service.newestCaptureBuffers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCaptureRunOwnerTest {
    @Test fun blockedCaptureConsumerRetainsOnlyNewestBufferAndCountsDroppedBuffers() = runBlocking {
        val consumingFirst = CompletableDeferred<Unit>()
        val releaseConsumer = CompletableDeferred<Unit>()
        val produced = CompletableDeferred<Unit>()
        val received = mutableListOf<Int>()
        var drops = 0L
        val source = flow {
            emit(1L to byteArrayOf(1))
            consumingFirst.await()
            for (index in 2..100) emit(index.toLong() to byteArrayOf(index.toByte()))
            produced.complete(Unit)
        }.newestCaptureBuffers { drops += it }
        val collector = launch {
            source.collect { bytes ->
                received += bytes.single().toInt()
                if (received.size == 1) { consumingFirst.complete(Unit); releaseConsumer.await() }
            }
        }
        produced.await()
        releaseConsumer.complete(Unit)
        collector.join()
        assertEquals(listOf(1, 100), received)
        assertEquals(98L, drops)
    }

    @Test fun oldCleanupCannotReleaseReplacementGuideResourcesOrFocus() {
        var focusReleases = 0
        var oldResourcesReleased = 0
        var newResourcesReleased = 0
        val owner = AudioCaptureRunOwner(Any()) { focusReleases++ }
        val old = owner.start { oldResourcesReleased++ }
        owner.stop()
        val current = owner.start { newResourcesReleased++ }
        owner.release(old)
        assertTrue(owner.isCurrent(current))
        assertEquals(1, oldResourcesReleased)
        assertEquals(0, newResourcesReleased)
        assertEquals(1, focusReleases)
        owner.stop()
        owner.release(current)
        assertEquals(1, newResourcesReleased)
        assertEquals(2, focusReleases)
    }

    @Test fun oldCleanupCannotAbandonReplacementGuestFocus() {
        var playing = false
        var focusReleases = 0
        var resourceReleases = 0
        val owner = AudioCaptureRunOwner(Any()) { if (!playing) focusReleases++ }
        val old = owner.start { resourceReleases++ }
        owner.stop()
        playing = true
        owner.release(old)
        assertFalse(owner.isActive)
        assertTrue(playing)
        assertEquals(1, resourceReleases)
        assertEquals(1, focusReleases)
    }

    @Test fun stopClosesCaptureWhoseFlowWasNeverCollectedExactlyOnce() {
        var closes = 0
        val owner = AudioCaptureRunOwner(Any()) {}
        val run = owner.start { closes++ }
        owner.stop()
        owner.stop()
        owner.release(run)
        assertEquals(1, closes)
        assertFalse(owner.isActive)
    }
}
