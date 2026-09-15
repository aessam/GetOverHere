package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyConnectionBudget
import com.aessam.comeoverhere.core.NearbySocketBridge
import com.aessam.comeoverhere.core.NearbyTCPConnection
import com.aessam.toursession.NearbyLaneRequest
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.AssetRequestPayload
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Actual sockets and the production proxy, not a second implementation of forwarding. */
class GatewayBridgeTest {
    @Test fun blockedReliableGatewayWriteReportsTimeoutAndReleasesOnlyItsLane() {
        val budget = NearbyConnectionBudget()
        val healthy = requireNotNull(budget.reserveBootstrap())
        assertTrue(healthy.promote(NearbyLaneRequest.Lane.ASSET))
        val errors = java.util.concurrent.LinkedBlockingQueue<String>()
        val closed = java.util.concurrent.CountDownLatch(1)
        val first = object : com.aessam.comeoverhere.core.NearbyByteConnection {
            override val input = java.io.ByteArrayInputStream(byteArrayOf(42))
            override val output = java.io.ByteArrayOutputStream()
            override fun close() = Unit
        }
        val blocked = object : com.aessam.comeoverhere.core.NearbyByteConnection {
            override val input = object : java.io.InputStream() {
                override fun read(): Int { check(closed.await(3, TimeUnit.SECONDS)); return -1 }
            }
            override val output = object : java.io.OutputStream() {
                override fun write(value: Int) {
                    check(closed.await(3, TimeUnit.SECONDS))
                    throw java.io.IOException("Closed blocked write")
                }
            }
            override fun close() { closed.countDown() }
        }
        try {
            NearbySocketBridge(budget, reliableWriteTimeoutMilliseconds = 30).use { bridge ->
                bridge.onError = { errors.add(it) }
                assertThrows(java.io.IOException::class.java) {
                    bridge.forwardConnected(first, blocked, NearbyLaneRequest.Lane.CONTROL)
                }
                assertTrue(requireNotNull(errors.poll(3, TimeUnit.SECONDS)).contains("write exceeded"))
                assertEquals(1, budget.snapshot().persistent)
                assertEquals(0, budget.snapshot().bootstrap)
            }
        } finally { healthy.close(); blocked.close() }
    }

    @Test fun sharedCapacityRejectsBeforeAcceptanceAndKeepsRejectionSocketWritable() {
        for (persistent in listOf(false, true)) {
            val budget = NearbyConnectionBudget(maximumParticipants = 1, maximumBootstrap = 1)
            val occupied = requireNotNull(budget.reserveBootstrap())
            if (persistent) assertTrue(occupied.promote(NearbyLaneRequest.Lane.CONTROL))
            val left = pair(); val right = pair()
            try {
                NearbySocketBridge(budget).use { bridge ->
                    var accepted = false
                    assertThrows(com.aessam.comeoverhere.core.NearbyLaneCapacityException::class.java) {
                        bridge.forwardConnected(NearbyTCPConnection(left.second), NearbyTCPConnection(right.second),
                            NearbyLaneRequest.Lane.CONTROL) { accepted = true }
                    }
                    assertTrue(!accepted)
                    left.second.getOutputStream().write(2)
                    assertEquals(2, left.first.getInputStream().read())
                    assertEquals(if (persistent) 1 else 0, budget.snapshot().persistent)
                    assertEquals(if (persistent) 0 else 1, budget.snapshot().bootstrap)
                }
            } finally {
                occupied.close(); left.first.close(); left.second.close(); right.first.close(); right.second.close()
            }
        }
    }

    @Test fun failedAcceptanceReleasesBothSocketsAndAllBudgets() {
        val budget = NearbyConnectionBudget()
        val left = pair(); val right = pair()
        try {
            NearbySocketBridge(budget).use { bridge ->
                assertThrows(java.io.IOException::class.java) {
                    bridge.forwardConnected(NearbyTCPConnection(left.second), NearbyTCPConnection(right.second),
                        NearbyLaneRequest.Lane.CONTROL) { throw java.io.IOException("Injected ACK write failure") }
                }
                assertTrue(left.second.isClosed && right.second.isClosed)
                assertEquals(0, budget.snapshot().persistent)
                assertEquals(0, budget.snapshot().bootstrap)
            }
        } finally { left.first.close(); left.second.close(); right.first.close(); right.second.close() }
    }

    @Test fun reliableWiredLanePreservesBytesInBothDirections() = probe(NearbyLaneRequest.Lane.CONTROL) { leaf, guide ->
        val outgoing = ByteArray(40_003) { (it * 17).toByte() }
        guide.getOutputStream().write(outgoing); guide.getOutputStream().flush()
        assertArrayEquals(outgoing, ByteArray(outgoing.size).also { DataInputStream(leaf.getInputStream()).readFully(it) })
        val reverse = ByteArray(117) { (it * 11).toByte() }
        leaf.getOutputStream().write(reverse); leaf.getOutputStream().flush()
        assertArrayEquals(reverse, ByteArray(reverse.size).also { DataInputStream(guide.getInputStream()).readFully(it) })
    }

    @Test fun wiredRealtimeForwardsCompleteImmutableFramesWithoutNativeACKs() = probe(NearbyLaneRequest.Lane.REALTIME) { leaf, guide ->
        val frame = ByteArray(244) { (it * 3).toByte() }.apply {
            byteArrayOf(71, 79, 72, 50).copyInto(this); this[4] = 4; this[7] = 0x10
        }
        DataOutputStream(guide.getOutputStream()).apply { writeInt(frame.size); write(frame); flush() }
        val input = DataInputStream(leaf.getInputStream())
        assertEquals(frame.size, input.readInt())
        assertArrayEquals(frame, ByteArray(frame.size).also(input::readFully))
        // A USB sender never receives the native radio's zero-length ACK protocol.
        assertEquals(0, guide.getInputStream().available())
        DataOutputStream(leaf.getOutputStream()).apply { writeInt(frame.size); write(frame); flush() }
        val reverse = DataInputStream(guide.getInputStream())
        assertEquals(frame.size, reverse.readInt())
        assertArrayEquals(frame, ByteArray(frame.size).also(reverse::readFully))
    }

    @Test fun assetLanePreserves64KiBChunksAndExplicitResumeRequestsAfterReopen() {
        val asset = ByteArray(131_189) { ((it * 29) xor (it ushr 8)).toByte() }
        val hash = MessageDigest.getInstance("SHA-256").digest(asset).joinToString("") { "%02x".format(it) }
        val received = ByteArray(asset.size)
        // Each probe closes its real sockets/bridge. The next connection must
        // preserve the caller's existing offset request, not invent resume state.
        for (offset in listOf(0, 65_536, 131_072)) {
            probe(NearbyLaneRequest.Lane.ASSET) { leaf, guide ->
                val request = AssetRequestPayload(hash, offset.toLong()).encode()
                DataOutputStream(leaf.getOutputStream()).apply { writeInt(request.size); write(request); flush() }
                val upstream = DataInputStream(guide.getInputStream())
                assertEquals(request.size, upstream.readInt())
                val forwardedRequest = ByteArray(request.size).also(upstream::readFully)
                assertArrayEquals(request, forwardedRequest)
                assertEquals(offset.toLong(), AssetRequestPayload.decode(forwardedRequest).offset)

                val end = minOf(offset + 65_536, asset.size)
                val chunk = AssetChunkPayload(hash, offset.toLong(), asset.size.toLong(), asset.copyOfRange(offset, end)).encode()
                DataOutputStream(guide.getOutputStream()).apply { writeInt(chunk.size); write(chunk); flush() }
                val downstream = DataInputStream(leaf.getInputStream())
                assertEquals(chunk.size, downstream.readInt())
                val forwardedChunk = ByteArray(chunk.size).also(downstream::readFully)
                assertArrayEquals(chunk, forwardedChunk)
                val decoded = AssetChunkPayload.decode(forwardedChunk)
                assertEquals(hash, decoded.sha256)
                assertEquals(offset.toLong(), decoded.offset)
                assertEquals(asset.size.toLong(), decoded.totalLength)
                decoded.bytes.copyInto(received, offset)
            }
        }
        assertArrayEquals(asset, received)
    }

    @Test fun stopClosesOldForwarderWithoutReleasingOtherOwnersBudget() {
        val budget = NearbyConnectionBudget(maximumParticipants = 1)
        val old = NearbySocketBridge(budget, audioResidenceMilliseconds = 50)
        val executor = Executors.newSingleThreadExecutor()
        val left = pair(); val right = pair()
        try {
            val worker = executor.submit { old.forwardConnected(NearbyTCPConnection(left.second), NearbyTCPConnection(right.second), NearbyLaneRequest.Lane.CONTROL) }
            right.first.getOutputStream().write(42)
            assertEquals(42, left.first.getInputStream().read())
            old.stop()
            val newOwner = requireNotNull(budget.reserveBootstrap())
            assertTrue(newOwner.promote(NearbyLaneRequest.Lane.CONTROL))
            try { worker.get(3, TimeUnit.SECONDS) }
            catch (error: java.util.concurrent.ExecutionException) {
                assertTrue("Intentional socket close must be the only worker failure", error.cause is java.net.SocketException)
            }
            assertEquals(1, budget.snapshot().persistent)
            newOwner.close()
        } finally { old.close(); left.first.close(); right.first.close(); executor.shutdownNow() }
    }

    private fun probe(lane: NearbyLaneRequest.Lane, action: (Socket, Socket) -> Unit) {
        val bridge = NearbySocketBridge(NearbyConnectionBudget(), audioResidenceMilliseconds = 50)
        val left = pair(); val right = pair(); val executor = Executors.newSingleThreadExecutor()
        try {
            executor.submit { bridge.forwardConnected(NearbyTCPConnection(left.second), NearbyTCPConnection(right.second), lane) }
            action(left.first, right.first)
        } finally { bridge.close(); left.first.close(); right.first.close(); executor.shutdownNow() }
    }

    private fun pair(): Pair<Socket, Socket> = ServerSocket().use { listener ->
        listener.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
        val client = Socket().apply { tcpNoDelay = true; soTimeout = 3_000; connect(listener.localSocketAddress) }
        client to listener.accept().apply { tcpNoDelay = true; soTimeout = 3_000 }
    }
}
