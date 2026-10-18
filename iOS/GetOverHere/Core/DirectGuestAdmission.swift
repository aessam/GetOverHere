import Foundation
import TourSessionCore

/**
 Exactly one heterogeneous link (ADR-081 T5, QST-1, user decision 2026-10-18). While the guide has assigned a
 bridge, direct guests of the other platform are limited to the bridge and at most two standbys; further ones are
 refused at the lane handshake and join through the bridge's island instead. Guests admitted earlier this session
 are always readmitted, and with no bridge assigned every guest is admitted. Thread-safe: lanes call it from their
 handshake threads.
 */
nonisolated final class DirectGuestAdmission: @unchecked Sendable {
    static let maximumStandbys = 2

    private let guidePlatform: ParticipantPlatform
    private let lock = NSLock()
    private var assignment: BridgeAssignmentPayload?
    private var admitted: Set<UUID> = []

    init(guidePlatform: ParticipantPlatform) {
        self.guidePlatform = guidePlatform
    }

    func update(assignment: BridgeAssignmentPayload?) {
        lock.withLock { self.assignment = assignment }
    }

    /// Decides one lane handshake; an admitted guest is remembered for the session. `relayCapable` is known only on
    /// the control lane (its hello carries the relayHost bit).
    func admits(participantID: UUID, platform: ParticipantPlatform, relayCapable: Bool) -> Bool {
        lock.withLock {
            let allowed = platform == guidePlatform || admitted.contains(participantID) || {
                guard let assignment else { return true }
                if participantID == assignment.bridgeID || assignment.standbyIDs.contains(participantID) { return true }
                // A relay-capable guest may take a free standby slot; the guide's next plan names it.
                return relayCapable && assignment.standbyIDs.count < Self.maximumStandbys
            }()
            if allowed { admitted.insert(participantID) }
            return allowed
        }
    }
}
