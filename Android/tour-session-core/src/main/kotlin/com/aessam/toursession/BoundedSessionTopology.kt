package com.aessam.toursession

import java.util.UUID

class SessionTopologyException(val reason: Reason) : IllegalArgumentException(reason.name) {
    enum class Reason {
        INVALID_CAPACITY, INVALID_LEASE, ROOT_CANNOT_BE_LISTENER, ALREADY_ATTACHED, UNKNOWN_PARTICIPANT,
        PARENT_NOT_QUALIFIED, CAPACITY_FULL, STALE_LEASE, LEASE_EXPIRED,
    }
}

/** Guide-owned planning record, not an admission or cryptographically authenticated relay ticket. */
data class SessionTopologyLease internal constructor(
    val participantId: UUID,
    val parentId: UUID,
    val depth: Int,
    val generation: Long,
    val expiresAtMilliseconds: Long,
    val relayChildLimit: Int?,
)

/** Root plus <=30 listeners including relays, <=2 delivery hops. Qualifications come from the caller's
 * device evidence, never from assuming a successful two-peer link qualifies a thirty-person group.
 */
class BoundedSessionTopology(val rootId: UUID, val rootChildLimit: Int?) {
    var generation: Long = 0
        private set
    private val members = mutableMapOf<UUID, SessionTopologyLease>()
    val listenerCount: Int get() = members.size
    val leases: List<SessionTopologyLease> get() = members.values.sortedBy { it.participantId.toString() }

    init {
        if (rootChildLimit != null && rootChildLimit !in 0..SessionCapacityPolicy.LISTENER_LIMIT) {
            fail(SessionTopologyException.Reason.INVALID_CAPACITY)
        }
    }

    fun attach(participantId: UUID, relayChildLimit: Int? = null, preferredParentId: UUID? = null,
        nowMilliseconds: Long, leaseDurationMilliseconds: Long): SessionTopologyLease {
        val expiry = expiry(nowMilliseconds, leaseDurationMilliseconds)
        validateRelayCapacity(relayChildLimit)
        if (participantId == rootId) fail(SessionTopologyException.Reason.ROOT_CANNOT_BE_LISTENER)
        if (participantId in members) fail(SessionTopologyException.Reason.ALREADY_ATTACHED)
        if (members.size >= SessionCapacityPolicy.LISTENER_LIMIT) fail(SessionTopologyException.Reason.CAPACITY_FULL)
        val parent = if (preferredParentId != null) {
            if (preferredParentId == participantId) fail(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED)
            requireAvailableParent(preferredParentId, nowMilliseconds)
            preferredParentId
        } else {
            val candidates = listOf(rootId) + members.values.filter { it.depth == 1 }
                .sortedBy { it.participantId.toString() }.map { it.participantId }
            val qualified = candidates.filter { childLimit(it) != null && isLive(it, nowMilliseconds) }
            if (qualified.isEmpty()) fail(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED)
            qualified.firstOrNull { childCount(it) < requireNotNull(childLimit(it)) }
                ?: fail(SessionTopologyException.Reason.CAPACITY_FULL)
        }
        val depth = if (parent == rootId) 1 else 2
        if (depth >= MAXIMUM_DEPTH && relayChildLimit != null && relayChildLimit > 0) {
            fail(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED)
        }
        return SessionTopologyLease(participantId, parent, depth, nextGeneration(), expiry, relayChildLimit)
            .also { members[participantId] = it }
    }

    fun renew(participantId: UUID, expectedGeneration: Long, nowMilliseconds: Long,
        leaseDurationMilliseconds: Long): SessionTopologyLease {
        val expiry = expiry(nowMilliseconds, leaseDurationMilliseconds)
        val current = requireLease(participantId, expectedGeneration)
        if (!isLive(participantId, nowMilliseconds)) fail(SessionTopologyException.Reason.LEASE_EXPIRED)
        return current.copy(generation = nextGeneration(), expiresAtMilliseconds = expiry).also { members[participantId] = it }
    }

    fun updateRelayCapacity(participantId: UUID, expectedGeneration: Long, childLimit: Int?,
        nowMilliseconds: Long): SessionTopologyLease {
        if (nowMilliseconds < 0) fail(SessionTopologyException.Reason.INVALID_LEASE)
        validateRelayCapacity(childLimit)
        val current = requireLease(participantId, expectedGeneration)
        if (!isLive(participantId, nowMilliseconds)) fail(SessionTopologyException.Reason.LEASE_EXPIRED)
        if (current.depth >= MAXIMUM_DEPTH && childLimit != null && childLimit > 0) {
            fail(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED)
        }
        if (childCount(participantId) > (childLimit ?: 0)) fail(SessionTopologyException.Reason.CAPACITY_FULL)
        return current.copy(generation = nextGeneration(), relayChildLimit = childLimit).also { members[participantId] = it }
    }

    /** An old route callback cannot remove the replacement lease/subtree. */
    fun detach(participantId: UUID, expectedGeneration: Long): List<UUID> {
        requireLease(participantId, expectedGeneration)
        return removeSubtrees(setOf(participantId))
    }

    /** Call before planning new attachments; expired entries reserve capacity until explicitly removed. */
    fun expire(nowMilliseconds: Long): List<UUID> {
        if (nowMilliseconds < 0) fail(SessionTopologyException.Reason.INVALID_LEASE)
        return removeSubtrees(members.values.filter { it.expiresAtMilliseconds <= nowMilliseconds }.map { it.participantId }.toSet())
    }

    private fun childLimit(id: UUID): Int? = if (id == rootId) rootChildLimit else
        members[id]?.let { if (it.depth < MAXIMUM_DEPTH) it.relayChildLimit else null }

    private fun childCount(id: UUID): Int = members.values.count { it.parentId == id }

    private fun isLive(id: UUID, now: Long): Boolean {
        if (id == rootId) return true
        val lease = members[id] ?: return false
        return lease.expiresAtMilliseconds > now && (lease.parentId == rootId ||
            (members[lease.parentId]?.expiresAtMilliseconds ?: 0) > now)
    }

    private fun requireAvailableParent(id: UUID, now: Long) {
        if (id != rootId && id !in members) fail(SessionTopologyException.Reason.UNKNOWN_PARTICIPANT)
        val limit = childLimit(id) ?: fail(SessionTopologyException.Reason.PARENT_NOT_QUALIFIED)
        if (!isLive(id, now)) fail(SessionTopologyException.Reason.LEASE_EXPIRED)
        if (childCount(id) >= limit) fail(SessionTopologyException.Reason.CAPACITY_FULL)
    }

    private fun requireLease(id: UUID, expected: Long): SessionTopologyLease {
        if (id == rootId) fail(SessionTopologyException.Reason.ROOT_CANNOT_BE_LISTENER)
        val lease = members[id] ?: fail(SessionTopologyException.Reason.UNKNOWN_PARTICIPANT)
        if (lease.generation != expected) fail(SessionTopologyException.Reason.STALE_LEASE)
        return lease
    }

    private fun removeSubtrees(roots: Set<UUID>): List<UUID> {
        val removed = roots.toMutableSet()
        repeat(MAXIMUM_DEPTH) { removed.addAll(members.values.filter { it.parentId in removed }.map { it.participantId }) }
        if (removed.isEmpty()) return emptyList()
        nextGeneration()
        removed.forEach { members.remove(it) }
        return removed.sortedBy { it.toString() }
    }

    private fun nextGeneration(): Long {
        if (generation == Long.MAX_VALUE) fail(SessionTopologyException.Reason.INVALID_LEASE)
        generation += 1
        return generation
    }

    companion object {
        const val MAXIMUM_DEPTH = 2
        const val MAXIMUM_RELAY_CHILDREN = 5
        const val MAXIMUM_LEASE_DURATION_MILLISECONDS = 300_000L

        private fun expiry(now: Long, duration: Long): Long {
            if (now < 0 || duration !in 1..MAXIMUM_LEASE_DURATION_MILLISECONDS || now > Long.MAX_VALUE - duration) {
                fail(SessionTopologyException.Reason.INVALID_LEASE)
            }
            return now + duration
        }

        private fun validateRelayCapacity(value: Int?) {
            if (value != null && value !in 0..MAXIMUM_RELAY_CHILDREN) fail(SessionTopologyException.Reason.INVALID_CAPACITY)
        }

        private fun fail(reason: SessionTopologyException.Reason): Nothing = throw SessionTopologyException(reason)
    }
}
