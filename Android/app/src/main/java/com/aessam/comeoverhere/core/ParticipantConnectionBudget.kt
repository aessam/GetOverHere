package com.aessam.comeoverhere.core

import java.io.Closeable
import java.util.UUID

/** A native lane admits at most 30 distinct members, including validated pending welcomes. */
internal class ParticipantConnectionBudget(private val maximumParticipants: Int = 30) {
    private val reservations = mutableMapOf<UUID, UUID>()
    init { require(maximumParticipants > 0) }

    @Synchronized fun reserve(participantID: UUID): Lease? {
        if (participantID !in reservations.values && reservations.values.toSet().size >= maximumParticipants) return null
        val id = UUID.randomUUID()
        reservations[id] = participantID
        return Lease(this, id)
    }

    @Synchronized fun clear() { reservations.clear() }
    @Synchronized fun participantCount(): Int = reservations.values.toSet().size
    @Synchronized private fun release(id: UUID) { reservations.remove(id) }

    class Lease internal constructor(private val owner: ParticipantConnectionBudget, private val id: UUID) : Closeable {
        override fun close() = owner.release(id)
    }
}
