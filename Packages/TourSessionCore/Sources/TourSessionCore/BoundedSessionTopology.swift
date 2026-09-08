import Foundation

public enum SessionTopologyError: Error, Equatable {
    case invalidCapacity, invalidLease, rootCannotBeListener, alreadyAttached, unknownParticipant
    case parentNotQualified, capacityFull, staleLease, leaseExpired
}

/// Planning state, not an admission or a signed relay ticket. Only the authoritative guide
/// owns/mutates the topology; transport peers cannot grant authority by constructing this value.
public struct SessionTopologyLease: Equatable, Sendable {
    public let participantID: UUID
    public let parentID: UUID
    public let depth: Int
    public let generation: UInt64
    public let expiresAtMilliseconds: UInt64
    public let relayChildLimit: Int?
}

/// Root plus at most thirty listeners (relay-listeners count), at most two delivery hops.
/// Caller qualifications are device/test evidence, not inferred from a successful two-peer link.
public struct BoundedSessionTopology: Sendable {
    public static let maximumDepth = 2
    public static let maximumRelayChildren = 5
    public static let maximumLeaseDurationMilliseconds: UInt64 = 300_000
    public let rootID: UUID
    public let rootChildLimit: Int?
    public private(set) var generation: UInt64 = 0
    private var members: [UUID: SessionTopologyLease] = [:]

    public init(rootID: UUID, rootChildLimit: Int?) throws {
        guard rootChildLimit.map({ (0...SessionCapacityPolicy.listenerLimit).contains($0) }) ?? true else {
            throw SessionTopologyError.invalidCapacity
        }
        self.rootID = rootID
        self.rootChildLimit = rootChildLimit
    }

    public var listenerCount: Int { members.count }
    public var leases: [SessionTopologyLease] { members.values.sorted { Self.ordered($0.participantID, $1.participantID) } }

    public mutating func attach(participantID: UUID, relayChildLimit: Int? = nil, preferredParentID: UUID? = nil,
        nowMilliseconds: UInt64, leaseDurationMilliseconds: UInt64) throws -> SessionTopologyLease {
        let expiry = try Self.expiry(nowMilliseconds, leaseDurationMilliseconds)
        try Self.validateRelayCapacity(relayChildLimit)
        guard participantID != rootID else { throw SessionTopologyError.rootCannotBeListener }
        guard members[participantID] == nil else { throw SessionTopologyError.alreadyAttached }
        guard members.count < SessionCapacityPolicy.listenerLimit else { throw SessionTopologyError.capacityFull }
        let parent: UUID
        if let requested = preferredParentID {
            guard requested != participantID else { throw SessionTopologyError.parentNotQualified }
            try requireAvailableParent(requested, nowMilliseconds: nowMilliseconds)
            parent = requested
        } else {
            let candidates = [rootID] + members.values.filter { $0.depth == 1 }.sorted {
                Self.ordered($0.participantID, $1.participantID)
            }.map(\.participantID)
            let qualified = candidates.filter { childLimit($0) != nil && isLive($0, nowMilliseconds) }
            guard !qualified.isEmpty else { throw SessionTopologyError.parentNotQualified }
            guard let chosen = qualified.first(where: { childCount($0) < childLimit($0)! }) else {
                throw SessionTopologyError.capacityFull
            }
            parent = chosen
        }
        let depth = parent == rootID ? 1 : 2
        guard depth < Self.maximumDepth || relayChildLimit == nil || relayChildLimit == 0 else {
            throw SessionTopologyError.parentNotQualified
        }
        let lease = SessionTopologyLease(participantID: participantID, parentID: parent, depth: depth,
            generation: try nextGeneration(), expiresAtMilliseconds: expiry, relayChildLimit: relayChildLimit)
        members[participantID] = lease
        return lease
    }

    public mutating func renew(participantID: UUID, expectedGeneration: UInt64, nowMilliseconds: UInt64,
        leaseDurationMilliseconds: UInt64) throws -> SessionTopologyLease {
        let expiry = try Self.expiry(nowMilliseconds, leaseDurationMilliseconds)
        let current = try requireLease(participantID, expectedGeneration)
        guard isLive(participantID, nowMilliseconds) else { throw SessionTopologyError.leaseExpired }
        let lease = SessionTopologyLease(participantID: participantID, parentID: current.parentID, depth: current.depth,
            generation: try nextGeneration(), expiresAtMilliseconds: expiry, relayChildLimit: current.relayChildLimit)
        members[participantID] = lease
        return lease
    }

    public mutating func updateRelayCapacity(participantID: UUID, expectedGeneration: UInt64, childLimit: Int?,
        nowMilliseconds: UInt64) throws -> SessionTopologyLease {
        try Self.validateRelayCapacity(childLimit)
        let current = try requireLease(participantID, expectedGeneration)
        guard isLive(participantID, nowMilliseconds) else { throw SessionTopologyError.leaseExpired }
        guard current.depth < Self.maximumDepth || childLimit == nil || childLimit == 0 else {
            throw SessionTopologyError.parentNotQualified
        }
        guard childCount(participantID) <= (childLimit ?? 0) else { throw SessionTopologyError.capacityFull }
        let lease = SessionTopologyLease(participantID: participantID, parentID: current.parentID, depth: current.depth,
            generation: try nextGeneration(), expiresAtMilliseconds: current.expiresAtMilliseconds, relayChildLimit: childLimit)
        members[participantID] = lease
        return lease
    }

    /// Generation guards keep a delayed old-route callback from removing a newly attached subtree.
    @discardableResult
    public mutating func detach(participantID: UUID, expectedGeneration: UInt64) throws -> [UUID] {
        _ = try requireLease(participantID, expectedGeneration)
        return try removeSubtrees(rootIDs: [participantID])
    }

    /// Call before planning new attachments. Expired entries retain capacity until explicitly removed.
    @discardableResult
    public mutating func expire(nowMilliseconds: UInt64) throws -> [UUID] {
        guard nowMilliseconds <= UInt64(Int64.max) else { throw SessionTopologyError.invalidLease }
        return try removeSubtrees(rootIDs: Set(members.values.filter {
            $0.expiresAtMilliseconds <= nowMilliseconds
        }.map(\.participantID)))
    }

    private func childLimit(_ id: UUID) -> Int? {
        id == rootID ? rootChildLimit : members[id].flatMap { $0.depth < Self.maximumDepth ? $0.relayChildLimit : nil }
    }

    private func childCount(_ id: UUID) -> Int { members.values.filter { $0.parentID == id }.count }

    private func isLive(_ id: UUID, _ now: UInt64) -> Bool {
        if id == rootID { return true }
        guard let lease = members[id], lease.expiresAtMilliseconds > now else { return false }
        return lease.parentID == rootID || (members[lease.parentID]?.expiresAtMilliseconds ?? 0) > now
    }

    private func requireAvailableParent(_ id: UUID, nowMilliseconds: UInt64) throws {
        guard id == rootID || members[id] != nil else { throw SessionTopologyError.unknownParticipant }
        guard let limit = childLimit(id) else { throw SessionTopologyError.parentNotQualified }
        guard isLive(id, nowMilliseconds) else { throw SessionTopologyError.leaseExpired }
        guard childCount(id) < limit else { throw SessionTopologyError.capacityFull }
    }

    private func requireLease(_ id: UUID, _ expected: UInt64) throws -> SessionTopologyLease {
        guard id != rootID else { throw SessionTopologyError.rootCannotBeListener }
        guard let lease = members[id] else { throw SessionTopologyError.unknownParticipant }
        guard lease.generation == expected else { throw SessionTopologyError.staleLease }
        return lease
    }

    private mutating func removeSubtrees(rootIDs: Set<UUID>) throws -> [UUID] {
        var removed = rootIDs
        for _ in 0..<Self.maximumDepth {
            removed.formUnion(members.values.filter { removed.contains($0.parentID) }.map(\.participantID))
        }
        guard !removed.isEmpty else { return [] }
        _ = try nextGeneration()
        for id in removed { members.removeValue(forKey: id) }
        return removed.sorted(by: Self.ordered)
    }

    private mutating func nextGeneration() throws -> UInt64 {
        guard generation < UInt64(Int64.max) else { throw SessionTopologyError.invalidLease }
        generation += 1
        return generation
    }

    private static func expiry(_ now: UInt64, _ duration: UInt64) throws -> UInt64 {
        guard duration > 0, duration <= maximumLeaseDurationMilliseconds,
              now <= UInt64(Int64.max) - duration else { throw SessionTopologyError.invalidLease }
        return now + duration
    }

    private static func validateRelayCapacity(_ value: Int?) throws {
        guard value.map({ (0...maximumRelayChildren).contains($0) }) ?? true else { throw SessionTopologyError.invalidCapacity }
    }

    private static func ordered(_ left: UUID, _ right: UUID) -> Bool { left.uuidString < right.uuidString }
}
