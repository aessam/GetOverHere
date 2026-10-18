import Foundation

public struct ParticipantSession: Equatable, Sendable {
    public let participantID: UUID
    public let connectionID: String
    public let displayName: String
    public let role: SessionRole
    public let platform: ParticipantPlatform
    /// `SessionCapabilities` from the guest's control-lane hello (e.g. `relayHost`, ADR-081).
    public let capabilities: UInt32

    public init(
        participantID: UUID,
        connectionID: String,
        displayName: String,
        role: SessionRole,
        platform: ParticipantPlatform,
        capabilities: UInt32 = 0
    ) {
        self.participantID = participantID
        self.connectionID = connectionID
        self.displayName = displayName
        self.role = role
        self.platform = platform
        self.capabilities = capabilities
    }
}

public struct ParticipantRegistry: Sendable {
    private var participantsByID: [UUID: ParticipantSession] = [:]
    private var participantIDByConnection: [String: UUID] = [:]

    public private(set) var version: UInt64 = 0

    public init() {}

    public var listenerCount: Int {
        participantsByID.values.lazy.filter { $0.role == .guest }.count
    }

    public var participants: [ParticipantSession] {
        participantsByID.values.sorted {
            $0.participantID.uuidString < $1.participantID.uuidString
        }
    }

    @discardableResult
    public mutating func register(_ participant: ParticipantSession) -> ParticipantSession? {
        let replaced = participantsByID[participant.participantID]
        if let replaced {
            participantIDByConnection.removeValue(forKey: replaced.connectionID)
        }

        if let displacedID = participantIDByConnection[participant.connectionID],
           displacedID != participant.participantID {
            participantsByID.removeValue(forKey: displacedID)
        }

        participantsByID[participant.participantID] = participant
        participantIDByConnection[participant.connectionID] = participant.participantID
        version &+= 1
        return replaced
    }

    @discardableResult
    public mutating func disconnect(connectionID: String) -> ParticipantSession? {
        guard let participantID = participantIDByConnection.removeValue(forKey: connectionID),
              let participant = participantsByID[participantID],
              participant.connectionID == connectionID else {
            return nil
        }
        participantsByID.removeValue(forKey: participantID)
        version &+= 1
        return participant
    }

    public func participant(for connectionID: String) -> ParticipantSession? {
        guard let participantID = participantIDByConnection[connectionID] else { return nil }
        return participantsByID[participantID]
    }
}
