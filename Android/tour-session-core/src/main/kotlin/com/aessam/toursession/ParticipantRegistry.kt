package com.aessam.toursession

import java.util.UUID

data class ParticipantSession(
    val participantId: UUID,
    val connectionId: String,
    val displayName: String,
    val role: SessionRole,
    val platform: ParticipantPlatform,
)

class ParticipantRegistry {
    private val participantsById = mutableMapOf<UUID, ParticipantSession>()
    private val participantIdByConnection = mutableMapOf<String, UUID>()

    var version: Long = 0
        private set

    val listenerCount: Int
        get() = participantsById.values.count { it.role == SessionRole.GUEST }

    val participants: List<ParticipantSession>
        get() = participantsById.values.sortedBy { it.participantId.toString() }

    fun register(participant: ParticipantSession): ParticipantSession? {
        val replaced = participantsById[participant.participantId]
        if (replaced != null) {
            participantIdByConnection.remove(replaced.connectionId)
        }

        val displacedId = participantIdByConnection[participant.connectionId]
        if (displacedId != null && displacedId != participant.participantId) {
            participantsById.remove(displacedId)
        }

        participantsById[participant.participantId] = participant
        participantIdByConnection[participant.connectionId] = participant.participantId
        version++
        return replaced
    }

    fun disconnect(connectionId: String): ParticipantSession? {
        val participantId = participantIdByConnection.remove(connectionId) ?: return null
        val participant = participantsById[participantId] ?: return null
        if (participant.connectionId != connectionId) return null
        participantsById.remove(participantId)
        version++
        return participant
    }

    fun participant(connectionId: String): ParticipantSession? {
        val participantId = participantIdByConnection[connectionId] ?: return null
        return participantsById[participantId]
    }
}
