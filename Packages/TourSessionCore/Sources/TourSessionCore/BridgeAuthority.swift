import Foundation

/// A guest the guide could assign as the cross-platform bridge (ADR-081 P2).
public struct BridgeCandidate: Equatable, Sendable {
    public let participantID: UUID
    public let platform: ParticipantPlatform
    public let capabilities: UInt32
    /// Order in which the guide admitted this guest; earlier guests are preferred.
    public let joinOrder: UInt64

    public init(participantID: UUID, platform: ParticipantPlatform, capabilities: UInt32, joinOrder: UInt64) {
        self.participantID = participantID; self.platform = platform
        self.capabilities = capabilities; self.joinOrder = joinOrder
    }
}

/// The guide's single source of truth for which guest bridges the other platform's island (ADR-081 D2). Pure and
/// byte-identical in both cores. The bridge is the first other-platform guest that advertises `relayHost`, kept while
/// it stays eligible; up to two more eligible guests are standbys. Any change of bridge or standbys bumps the
/// generation; renewing a lease keeps it (far guests verify the generation their host advertises).
public struct BridgeAuthority: Sendable {
    public static let leaseMilliseconds: UInt64 = 60_000
    public let guidePlatform: ParticipantPlatform
    public private(set) var current: BridgeAssignmentPayload?
    private var generation: UInt64 = 0

    public init(guidePlatform: ParticipantPlatform) {
        self.guidePlatform = guidePlatform
    }

    /// The assignment the guide should send now, or nil when nothing changed and the lease has more than half left.
    public mutating func plan(candidates: [BridgeCandidate], nowMilliseconds: UInt64) throws -> BridgeAssignmentPayload? {
        let eligible = candidates
            .filter { $0.platform != guidePlatform && $0.platform != .host
                && SessionCapabilities(rawValue: $0.capabilities).contains(.relayHost) }
            .sorted { $0.joinOrder != $1.joinOrder ? $0.joinOrder < $1.joinOrder
                : $0.participantID.uuidString < $1.participantID.uuidString }
        guard let first = eligible.first else {
            current = nil
            return nil
        }
        let bridge = current.flatMap { held in eligible.first { $0.participantID == held.bridgeID } } ?? first
        let standbys = Array(eligible.filter { $0.participantID != bridge.participantID }
            .prefix(BridgeAssignmentPayload.maximumStandbys).map(\.participantID))
        let expires = nowMilliseconds + Self.leaseMilliseconds
        if let held = current, held.bridgeID == bridge.participantID, held.standbyIDs == standbys {
            guard held.leaseExpiresAtMilliseconds <= nowMilliseconds + Self.leaseMilliseconds / 2 else { return nil }
            current = try BridgeAssignmentPayload(generation: held.generation, bridgeID: held.bridgeID,
                bridgePlatform: held.bridgePlatform, leaseExpiresAtMilliseconds: expires, standbyIDs: standbys)
            return current
        }
        generation += 1
        current = try BridgeAssignmentPayload(generation: generation, bridgeID: bridge.participantID,
            bridgePlatform: bridge.platform, leaseExpiresAtMilliseconds: expires, standbyIDs: standbys)
        return current
    }
}
