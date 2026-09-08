package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionCapacityTopologyTest {
    private fun id(index: Int): UUID = UUID.fromString("00000000-0000-0000-0000-%012x".format(index))
    private fun rejected(reason: SessionTopologyException.Reason, body: () -> Unit) {
        assertEquals(reason, assertThrows(SessionTopologyException::class.java, body).reason)
    }

    @Test fun explicitBluetoothRoutePreservesExistingOrderingAndRawValues() {
        assertEquals(1, SessionTransportRoute.LOCAL_LAN.rawValue)
        assertEquals(2, SessionTransportRoute.WIFI_AWARE.rawValue)
        assertEquals(3, SessionTransportRoute.BLUETOOTH.rawValue)
        assertEquals(listOf(SessionTransportRoute.LOCAL_LAN, SessionTransportRoute.WIFI_AWARE), SessionRouteAvailability(true, true).orderedRoutes)
        assertEquals(SessionTransportRoute.entries, SessionRouteAvailability(true, true, true).orderedRoutes)
        assertEquals(listOf(SessionTransportRoute.BLUETOOTH), SessionRouteAvailability(false, false, true).orderedRoutes)
        val lease = SessionRouteLease()
        assertTrue(lease.select(SessionTransportRoute.BLUETOOTH))
        assertFalse(lease.select(SessionTransportRoute.WIFI_AWARE))
    }

    @Test fun softwareBudgetIsNotRadioCapacityAndUpstreamIsSubtractedOnce() {
        assertEquals(30, SessionCapacityPolicy.LISTENER_LIMIT)
        assertEquals(98, SessionCapacityPolicy.MAXIMUM_BRIDGE_CONNECTIONS)
        assertNull(SessionCapacityPolicy.usableDirectPeerLimit(null, null, 0, 0))
        assertEquals(1, SessionCapacityPolicy.usableDirectPeerLimit(1, 1, 0, 0))
        assertEquals(5, SessionCapacityPolicy.usableDirectPeerLimit(8, 2, 5, 1, 1))
        assertEquals(6, SessionCapacityPolicy.usableDirectPeerLimit(null, 2, 5, 1))
        assertEquals(6, SessionCapacityPolicy.usableDirectPeerLimit(8, null, 5, 1, 1))
        assertEquals(30, SessionCapacityPolicy.usableDirectPeerLimit(100, 100, 0, 0))
        assertEquals(0, SessionCapacityPolicy.usableDirectPeerLimit(1, 0, 1, 1, 1))
        listOf(listOf(-1, 0, 0, 0, 0), listOf(8, -1, 0, 0, 0), listOf(8, 0, -1, 0, 0),
            listOf(8, 0, 0, -1, 0), listOf(8, 0, 0, 0, -1), listOf(8, 1, 8, 0, 0),
            listOf(8, 0, 9, 0, 0), listOf(Int.MAX_VALUE, Int.MAX_VALUE, 1, 0, 0),
            listOf(8, 0, 0, Int.MAX_VALUE, 1)).forEach { args ->
            assertThrows(Exception::class.java) {
                SessionCapacityPolicy.usableDirectPeerLimit(args[0], args[1], args[2], args[3], args[4])
            }
        }
    }

    @Test fun thirtyListenersIncludeFiveRelaysAndTwentyFiveLeaves() {
        val tree = BoundedSessionTopology(id(0), 5)
        for (index in 5 downTo 1) tree.attach(id(index), relayChildLimit = 5, nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
        for (index in 6..30) {
            val lease = tree.attach(id(index), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
            assertEquals(2, lease.depth)
            assertEquals(id((index - 6) / 5 + 1), lease.parentId)
        }
        assertEquals(30, tree.listenerCount)
        assertEquals(30L, tree.generation)
        assertEquals(5, tree.leases.count { it.depth == 1 })
        assertFalse(tree.leases.any { it.participantId == id(0) })
        rejected(SessionTopologyException.Reason.CAPACITY_FULL) {
            tree.attach(id(31), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
        }
        for (relay in 1..5) assertEquals(5, tree.leases.count { it.parentId == id(relay) })
    }

    @Test fun explicitDirectStarAndUnknownCapacityNeverInventRelays() {
        val star = BoundedSessionTopology(id(0), 30)
        for (index in 1..30) {
            val lease = star.attach(id(index), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
            assertEquals(1, lease.depth)
            assertEquals(id(0), lease.parentId)
        }
        val unknown = BoundedSessionTopology(id(0), null)
        rejected(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED) {
            unknown.attach(id(1), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
        }
        val exhausted = BoundedSessionTopology(id(0), 0)
        rejected(SessionTopologyException.Reason.CAPACITY_FULL) {
            exhausted.attach(id(1), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
        }
    }

    @Test fun promotionDuplicateParentsDepthAndStaleRouteCallbacksAreBounded() {
        val tree = BoundedSessionTopology(id(0), 1)
        val original = tree.attach(id(1), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
        rejected(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED) {
            tree.attach(id(2), preferredParentId = id(1), nowMilliseconds = 0, leaseDurationMilliseconds = 1000)
        }
        val relay = tree.updateRelayCapacity(id(1), original.generation, 5, 1)
        val child = tree.attach(id(2), preferredParentId = id(1), nowMilliseconds = 1, leaseDurationMilliseconds = 1000)
        val snapshot = tree.leases
        rejected(SessionTopologyException.Reason.ALREADY_ATTACHED) {
            tree.attach(id(2), preferredParentId = id(0), nowMilliseconds = 1, leaseDurationMilliseconds = 1000)
        }
        rejected(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED) {
            tree.attach(id(3), preferredParentId = id(2), nowMilliseconds = 1, leaseDurationMilliseconds = 1000)
        }
        rejected(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED) {
            tree.updateRelayCapacity(id(2), child.generation, 1, 1)
        }
        rejected(SessionTopologyException.Reason.CAPACITY_FULL) { tree.updateRelayCapacity(id(1), relay.generation, null, 1) }
        rejected(SessionTopologyException.Reason.STALE_LEASE) { tree.detach(id(1), original.generation) }
        assertEquals(snapshot, tree.leases)
        assertEquals(listOf(id(1), id(2)), tree.detach(id(1), relay.generation))
        val replacement = tree.attach(id(1), nowMilliseconds = 2, leaseDurationMilliseconds = 1000)
        assertTrue(replacement.generation > relay.generation)
        rejected(SessionTopologyException.Reason.STALE_LEASE) { tree.detach(id(1), relay.generation) }
        assertEquals(1, tree.listenerCount)
    }

    @Test fun leaseRenewalExpiryAndSubtreeRemovalRejectResurrection() {
        val tree = BoundedSessionTopology(id(0), 2)
        val relay = tree.attach(id(1), relayChildLimit = 5, nowMilliseconds = 0, leaseDurationMilliseconds = 100)
        val other = tree.attach(id(2), nowMilliseconds = 0, leaseDurationMilliseconds = 500)
        val child = tree.attach(id(3), preferredParentId = id(1), nowMilliseconds = 0, leaseDurationMilliseconds = 500)
        assertTrue(tree.expire(99).isEmpty())
        rejected(SessionTopologyException.Reason.LEASE_EXPIRED) { tree.renew(id(3), child.generation, 100, 500) }
        rejected(SessionTopologyException.Reason.LEASE_EXPIRED) {
            tree.attach(id(4), preferredParentId = id(1), nowMilliseconds = 100, leaseDurationMilliseconds = 500)
        }
        assertEquals(listOf(relay.participantId, child.participantId), tree.expire(100))
        assertEquals(1, tree.listenerCount)
        val renewed = tree.renew(other.participantId, other.generation, 100, 600)
        assertEquals(700L, renewed.expiresAtMilliseconds)
        rejected(SessionTopologyException.Reason.STALE_LEASE) { tree.renew(other.participantId, other.generation, 100, 600) }
        assertEquals(listOf(other.participantId), tree.expire(700))
    }

    @Test fun invalidCapacitySelfAttachmentAndUnboundedLeasesReject() {
        listOf(-1, 31).forEach { limit -> assertThrows(Exception::class.java) { BoundedSessionTopology(id(0), limit) } }
        val tree = BoundedSessionTopology(id(0), 5)
        rejected(SessionTopologyException.Reason.ROOT_CANNOT_BE_LISTENER) {
            tree.attach(id(0), nowMilliseconds = 0, leaseDurationMilliseconds = 100)
        }
        rejected(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED) {
            tree.attach(id(1), preferredParentId = id(1), nowMilliseconds = 0, leaseDurationMilliseconds = 100)
        }
        rejected(SessionTopologyException.Reason.UNKNOWN_PARTICIPANT) {
            tree.attach(id(1), preferredParentId = id(2), nowMilliseconds = 0, leaseDurationMilliseconds = 100)
        }
        listOf(0L, -1L, 300_001L, Long.MAX_VALUE).forEach { duration ->
            rejected(SessionTopologyException.Reason.INVALID_LEASE) {
                tree.attach(id(1), nowMilliseconds = 0, leaseDurationMilliseconds = duration)
            }
        }
        rejected(SessionTopologyException.Reason.INVALID_LEASE) {
            tree.attach(id(1), nowMilliseconds = Long.MAX_VALUE, leaseDurationMilliseconds = 1)
        }
        rejected(SessionTopologyException.Reason.INVALID_CAPACITY) {
            tree.attach(id(1), relayChildLimit = 6, nowMilliseconds = 0, leaseDurationMilliseconds = 100)
        }
        assertEquals(0, tree.listenerCount)
        assertEquals(0L, tree.generation)
    }
}
