package com.aessam.toursession

import java.util.UUID

/** A guest the guide could assign as the cross-platform bridge (ADR-081 P2). */
data class BridgeCandidate(val participantID: UUID, val platform: ParticipantPlatform, val capabilities: Long, val joinOrder: Long)

/**
 * The guide's single source of truth for which guest bridges the other platform's island (ADR-081 D2). Pure and
 * byte-identical to the Swift BridgeAuthority. The bridge is the first other-platform guest that advertises
 * RELAY_HOST, kept while it stays eligible; up to two more eligible guests are standbys. Any change of bridge or
 * standbys bumps the generation; renewing a lease keeps it (far guests verify the generation their host advertises).
 */
class BridgeAuthority(val guidePlatform: ParticipantPlatform) {
    var current: BridgeAssignmentPayload? = null
        private set
    private var generation = 0L

    /** The assignment the guide should send now, or null when nothing changed and the lease has more than half left. */
    fun plan(candidates: List<BridgeCandidate>, nowMilliseconds: Long): BridgeAssignmentPayload? {
        val eligible = candidates
            .filter { it.platform != guidePlatform && it.platform != ParticipantPlatform.HOST &&
                it.capabilities and SessionCapability.RELAY_HOST.bit != 0L }
            .sortedWith(compareBy<BridgeCandidate> { it.joinOrder }.thenBy { it.participantID.toString().uppercase() })
        val first = eligible.firstOrNull() ?: run { current = null; return null }
        val held = current
        val bridge = held?.let { h -> eligible.firstOrNull { it.participantID == h.bridgeID } } ?: first
        val standbys = eligible.filter { it.participantID != bridge.participantID }
            .take(BridgeAssignmentPayload.MAXIMUM_STANDBYS).map { it.participantID }
        val expires = nowMilliseconds + LEASE_MILLISECONDS
        if (held != null && held.bridgeID == bridge.participantID && held.standbyIDs == standbys) {
            if (held.leaseExpiresAtMilliseconds > nowMilliseconds + LEASE_MILLISECONDS / 2) return null
            return held.copy(leaseExpiresAtMilliseconds = expires).also { current = it }
        }
        generation += 1
        return BridgeAssignmentPayload(generation, bridge.participantID, bridge.platform, expires, standbys).also { current = it }
    }

    companion object {
        const val LEASE_MILLISECONDS = 60_000L
    }
}
