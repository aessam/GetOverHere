package com.aessam.comeoverhere.core

import com.aessam.toursession.NearbyLaneRequest
import java.io.Closeable
import java.util.UUID

/** App-level adapter/socket budget, not Wi-Fi Aware data paths or qualified radio capacity. */
class NearbyConnectionBudget(
    val maximumParticipants: Int = 30,
    val maximumBootstrap: Int = 8,
) {
    data class Snapshot(val bootstrap: Int, val persistent: Int, val byLane: Map<NearbyLaneRequest.Lane, Int>)
    private data class Reservation(var lane: NearbyLaneRequest.Lane? = null)
    private val reservations = mutableMapOf<UUID, Reservation>()

    init { require(maximumParticipants > 0 && maximumBootstrap > 0) }

    @Synchronized fun snapshot(): Snapshot {
        val byLane = reservations.values.mapNotNull { it.lane }.groupingBy { it }.eachCount()
        return Snapshot(reservations.values.count { it.lane == null }, byLane.values.sum(), byLane)
    }

    @Synchronized fun reserveBootstrap(): Lease? {
        if (reservations.values.count { it.lane == null } >= maximumBootstrap) return null
        val id = UUID.randomUUID()
        reservations[id] = Reservation()
        return Lease(this, id)
    }

    @Synchronized private fun promote(id: UUID, lane: NearbyLaneRequest.Lane): Boolean {
        require(lane in persistentLanes) { "Metadata and admission cannot hold persistent slots" }
        val reservation = reservations[id] ?: return false
        if (reservation.lane != null) return reservation.lane == lane
        if (reservations.values.count { it.lane == lane } >= maximumParticipants) return false
        reservation.lane = lane
        return true
    }

    @Synchronized private fun release(id: UUID) { reservations.remove(id) }

    class Lease internal constructor(private val owner: NearbyConnectionBudget, private val id: UUID) : Closeable {
        fun promote(lane: NearbyLaneRequest.Lane): Boolean = owner.promote(id, lane)
        override fun close() = owner.release(id)
    }

    companion object {
        val sharedApp = NearbyConnectionBudget()
        val persistentLanes = setOf(NearbyLaneRequest.Lane.REALTIME, NearbyLaneRequest.Lane.CONTROL, NearbyLaneRequest.Lane.ASSET)
    }
}
