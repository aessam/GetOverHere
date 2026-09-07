package com.aessam.toursession

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class NearbyRealtimeQueueTest {
    @Test fun dropsStaleAudioButPreservesHandshakeAndRecentFrames() {
        val queue = NearbyRealtimeQueue()
        queue.offer(byteArrayOf(99), false, 0)
        repeat(100) { queue.offer(byteArrayOf(it.toByte()), true, it.toLong()) }
        assertEquals(8, queue.count)
        assertEquals(93, queue.dropped)
        assertArrayEquals(byteArrayOf(99), queue.next(245))
        assertArrayEquals(byteArrayOf(95), queue.next(245))
        assertEquals(95, queue.dropped)
        assertNull(queue.next(1_000))
    }
    @Test fun reliableOverflowRejectsInsteadOfLosingHandshake() {
        val queue = NearbyRealtimeQueue()
        repeat(8) { queue.offer(byteArrayOf(it.toByte()), false, 0) }
        assertThrows(IllegalArgumentException::class.java) { queue.offer(byteArrayOf(9), true, 1) }
        repeat(8) { assertArrayEquals(byteArrayOf(it.toByte()), queue.next(100_000)) }
        assertEquals(0, queue.dropped)
    }
}
