package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.NearbyConnectionBudget
import com.aessam.comeoverhere.core.NearbySocketBridge
import com.aessam.comeoverhere.core.ParticipantConnectionBudget
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.NearbyLaneRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NearbyConnectionBudgetTest {
    @Test fun defaultBudgetAllowsNinetyPersistentAndEightBootstrapNotNinetyEightPeers() {
        val budget = NearbyConnectionBudget()
        val leases = mutableListOf<NearbyConnectionBudget.Lease>()
        try {
            NearbyConnectionBudget.persistentLanes.forEach { lane ->
                repeat(30) { leases += requireNotNull(budget.reserveBootstrap()).also { assertTrue(it.promote(lane)) } }
            }
            val transient = List(8) { requireNotNull(budget.reserveBootstrap()) }.also(leases::addAll)
            assertEquals(90, budget.snapshot().persistent)
            assertEquals(8, budget.snapshot().bootstrap)
            assertNull(budget.reserveBootstrap())
            assertFalse(transient.first().promote(NearbyLaneRequest.Lane.CONTROL))
            assertEquals(8, budget.snapshot().bootstrap)
            leases.first().close(); leases.first().close()
            assertTrue(transient.first().promote(NearbyLaneRequest.Lane.REALTIME))
            assertFalse(transient.first().promote(NearbyLaneRequest.Lane.ASSET))
            assertEquals(7, budget.snapshot().bootstrap)
        } finally { leases.forEach { it.close() } }
        assertEquals(0, budget.snapshot().persistent + budget.snapshot().bootstrap)
    }

    @Test(timeout = 10_000) fun threeBridgesShareQuotaAndStoppingOneReleasesOnlyItsOwnConnections() {
        val budget = NearbyConnectionBudget(maximumParticipants = 1, maximumBootstrap = 2)
        val record = BluetoothRoomRecord(UUID.randomUUID(), UUID.randomUUID(), "Tour", false, false)
        val bridges = List(3) { NearbySocketBridge(budget, localConnect = { HeldConnection() }) }
        try {
            val control = HeldConnection(NearbyLaneRequest(NearbyLaneRequest.Lane.CONTROL, record.roomID).encode())
            bridges[0].accept(control) { record }
            assertTrue(control.written.await(2, TimeUnit.SECONDS))
            assertEquals(1, budget.snapshot().persistent)
            val excess = HeldConnection(NearbyLaneRequest(NearbyLaneRequest.Lane.CONTROL, record.roomID).encode())
            bridges[1].accept(excess) { record }
            assertTrue(excess.closed.await(2, TimeUnit.SECONDS))
            awaitCondition { budget.snapshot().bootstrap == 0 }
            assertEquals(1, budget.snapshot().persistent)
            val pending = HeldConnection()
            bridges[1].accept(pending) { record }
            val otherPending = HeldConnection()
            bridges[2].accept(otherPending) { record }
            assertEquals(2, budget.snapshot().bootstrap)
            val rejected = HeldConnection()
            bridges[0].accept(rejected) { record }
            assertTrue(rejected.closed.await(2, TimeUnit.SECONDS))
            bridges[1].stop(); bridges[1].stop()
            assertEquals(1, budget.snapshot().bootstrap)
            assertEquals(1, budget.snapshot().persistent)
            assertEquals(1L, control.closed.count)
            assertEquals(1L, otherPending.closed.count)
            bridges[0].stop()
            assertEquals(0, budget.snapshot().persistent)
            assertEquals(1, budget.snapshot().bootstrap)
        } finally { bridges.forEach { it.close() } }
        assertEquals(0, budget.snapshot().persistent + budget.snapshot().bootstrap)
    }

    @Test(timeout = 10_000) fun metadataReservesBeforeConnectAndStopClosesLateReturnedHandle() {
        val budget = NearbyConnectionBudget(maximumBootstrap = 1)
        val bridge = NearbySocketBridge(budget)
        val other = NearbySocketBridge(budget)
        val entered = CountDownLatch(1)
        val releaseConnect = CountDownLatch(1)
        val returned = HeldConnection()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val read = executor.submit<Boolean> {
                assertThrows(IllegalStateException::class.java) {
                    bridge.readRecord { entered.countDown(); check(releaseConnect.await(3, TimeUnit.SECONDS)); returned }
                }
                true
            }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertEquals(1, budget.snapshot().bootstrap)
            assertThrows(IllegalArgumentException::class.java) { other.readRecord { error("Quota bypassed") } }
            bridge.stop()
            assertEquals(0, budget.snapshot().bootstrap)
            val newOwner = requireNotNull(budget.reserveBootstrap())
            releaseConnect.countDown()
            assertTrue(read.get(3, TimeUnit.SECONDS))
            assertTrue(returned.closed.await(2, TimeUnit.SECONDS))
            assertEquals("Stale cleanup must not release a new owner", 1, budget.snapshot().bootstrap)
            newOwner.close()
        } finally { releaseConnect.countDown(); bridge.close(); other.close(); executor.shutdownNow() }
    }

    @Test fun nativeParticipantReplacementDoesNotDoubleCountOrReleaseCurrentOwner() {
        val budget = ParticipantConnectionBudget(1)
        val member = UUID.randomUUID()
        val old = requireNotNull(budget.reserve(member))
        val replacement = requireNotNull(budget.reserve(member))
        assertNull(budget.reserve(UUID.randomUUID()))
        old.close(); old.close()
        assertEquals(1, budget.participantCount())
        assertNull(budget.reserve(UUID.randomUUID()))
        budget.clear()
        val next = requireNotNull(budget.reserve(UUID.randomUUID()))
        replacement.close()
        assertEquals(1, budget.participantCount())
        next.close()
        assertEquals(0, budget.participantCount())
    }

    /** Blocks until close, like a pending native stream, without involving radios. */
    private class HeldConnection(prefix: ByteArray = ByteArray(0)) : NearbyByteConnection {
        val closed = CountDownLatch(1)
        val written = CountDownLatch(1)
        private val prefixInput = ByteArrayInputStream(prefix)
        override val input = object : InputStream() {
            override fun read(): Int {
                val byte = prefixInput.read()
                if (byte >= 0) return byte
                check(closed.await(8, TimeUnit.SECONDS)) { "Held stream did not close" }
                return -1
            }
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                if (length == 0) return 0
                val first = read()
                if (first == -1) return -1
                bytes[offset] = first.toByte()
                var count = 1
                while (count < length && prefixInput.available() > 0) bytes[offset + count++] = prefixInput.read().toByte()
                return count
            }
        }
        override val output = object : ByteArrayOutputStream() {
            override fun write(byte: Int) { super.write(byte); written.countDown() }
        }
        override fun close() { closed.countDown() }
    }

    private fun awaitCondition(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        while (!condition()) {
            check(System.nanoTime() < deadline) { "Budget cleanup timed out" }
            java.util.concurrent.locks.LockSupport.parkNanos(1_000_000)
        }
    }
}
