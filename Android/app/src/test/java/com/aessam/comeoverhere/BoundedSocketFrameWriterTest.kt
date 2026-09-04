package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.BoundedSocketFrameWriter
import com.aessam.comeoverhere.core.SocketFrameOverflowPolicy
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class BoundedSocketFrameWriterTest {
    @Test
    fun stalledWriterCannotBlockHealthyPeerWriter() {
        val server = ServerSocket(0)
        val stalledPeer = Socket("127.0.0.1", server.localPort)
        val stalledSocket = server.accept().apply { sendBufferSize = 2_048 }
        val healthyPeer = Socket("127.0.0.1", server.localPort)
        val healthySocket = server.accept()
        val stalledFailure = CountDownLatch(1)
        // The failure handler runs on the writer's daemon thread, where a thrown AssertionError is
        // invisible to JUnit; record and assert on the test thread instead (FND-12).
        val stalledGeneration = AtomicLong(-1)
        val healthyFailure = AtomicReference<String?>(null)
        val stalledWriter = BoundedSocketFrameWriter(
            socket = stalledSocket,
            generation = 11,
            label = "test-stalled-writer",
            capacity = 2,
            overflowPolicy = SocketFrameOverflowPolicy.DROP_OLDEST,
            sendTimeoutMillis = 100,
        ) { _, generation ->
            stalledGeneration.set(generation)
            stalledFailure.countDown()
        }
        val healthyWriter = BoundedSocketFrameWriter(
            socket = healthySocket,
            generation = 12,
            label = "test-healthy-writer",
            capacity = 2,
            overflowPolicy = SocketFrameOverflowPolicy.DISCONNECT,
            sendTimeoutMillis = 500,
        ) { _, generation -> healthyFailure.compareAndSet(null, "healthy writer failed (generation=$generation)") }

        try {
            stalledWriter.enqueue(ByteArray(4 * 1_024 * 1_024) { 0x5a })
            val payload = byteArrayOf(0x47, 0x4f, 0x48, 0x32)
            val delivery = checkNotNull(healthyWriter.enqueue(payload, trackDelivery = true))
            assertTrue(delivery.await(System.nanoTime() + TimeUnit.SECONDS.toNanos(1)))

            val input = DataInputStream(healthyPeer.getInputStream())
            val header = ByteArray(4).also(input::readFully)
            val length = ByteBuffer.wrap(header).int
            assertEquals(payload.size, length)
            val received = ByteArray(length).also(input::readFully)
            assertArrayEquals(payload, received)
            assertTrue(stalledFailure.await(2, TimeUnit.SECONDS))
            assertEquals(11L, stalledGeneration.get())
            assertNull(healthyFailure.get())
        } finally {
            stalledWriter.close()
            healthyWriter.close()
            stalledPeer.close()
            healthyPeer.close()
            server.close()
        }
    }
}
