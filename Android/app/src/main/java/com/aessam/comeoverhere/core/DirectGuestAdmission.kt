package com.aessam.comeoverhere.core

import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.ParticipantPlatform
import java.util.UUID

/**
 * Exactly one heterogeneous link (ADR-081 T5, QST-1, user decision 2026-10-18). While the guide has assigned a
 * bridge, direct guests of the other platform are limited to the bridge and at most two standbys; further ones are
 * refused at the lane handshake and join through the bridge's island instead. Guests admitted earlier this session
 * are always readmitted, and with no bridge assigned every guest is admitted. Thread-safe: lanes call it from their
 * handshake threads.
 */
class DirectGuestAdmission(private val guidePlatform: ParticipantPlatform) {
    private var assignment: BridgeAssignmentPayload? = null
    private val admitted = mutableSetOf<UUID>()

    @Synchronized fun update(assignment: BridgeAssignmentPayload?) { this.assignment = assignment }

    /** Decides one lane handshake; an admitted guest is remembered for the session. [relayCapable] is known only on
     *  the control lane (its hello carries the relayHost bit). */
    @Synchronized fun admits(participantID: UUID, platform: ParticipantPlatform, relayCapable: Boolean): Boolean {
        val current = assignment
        val allowed = platform == guidePlatform || participantID in admitted || current == null ||
            participantID == current.bridgeID || participantID in current.standbyIDs ||
            // A relay-capable guest may take a free standby slot; the guide's next plan names it.
            (relayCapable && current.standbyIDs.size < MAXIMUM_STANDBYS)
        if (allowed) admitted += participantID
        return allowed
    }

    companion object { const val MAXIMUM_STANDBYS = 2 }
}
