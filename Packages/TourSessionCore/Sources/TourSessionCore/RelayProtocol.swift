import CryptoKit
import Foundation

/// Cross-island relay (ADR-081, CrossIslandDesign.md). Pure, byte-identical in both cores; no I/O.

public enum RelayProtocolError: Error, Equatable, Sendable {
    case invalidPlatform(UInt8)
    case tooManyStandbys(Int)
    case invalidVersion(UInt8)
    case invalidLane(UInt8)
    case frameTooLarge(Int)
    case truncated
    case trailingBytes(Int)
}

/// W1: the guide's signed choice of the single cross-platform bridge (control lane, kind 0x25).
/// Only the guide sends it; a far guest whose host does not match the newest generation disconnects.
public struct BridgeAssignmentPayload: Equatable, Sendable {
    public static let maximumStandbys = 2
    public let generation: UInt64
    public let bridgeID: UUID
    public let bridgePlatform: ParticipantPlatform
    public let leaseExpiresAtMilliseconds: UInt64
    public let standbyIDs: [UUID]

    public init(generation: UInt64, bridgeID: UUID, bridgePlatform: ParticipantPlatform,
                leaseExpiresAtMilliseconds: UInt64, standbyIDs: [UUID]) throws {
        guard standbyIDs.count <= Self.maximumStandbys else { throw RelayProtocolError.tooManyStandbys(standbyIDs.count) }
        self.generation = generation
        self.bridgeID = bridgeID
        self.bridgePlatform = bridgePlatform
        self.leaseExpiresAtMilliseconds = leaseExpiresAtMilliseconds
        self.standbyIDs = standbyIDs
    }

    public func encode() -> Data {
        var writer = BinaryWriter(capacity: 42 + 16 * standbyIDs.count)
        writer.append(generation)
        writer.append(bridgeID)
        writer.append(bridgePlatform.rawValue)
        writer.append(leaseExpiresAtMilliseconds)
        writer.append(UInt8(standbyIDs.count))
        standbyIDs.forEach { writer.append($0) }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> BridgeAssignmentPayload {
        var reader = BinaryReader(data: data)
        let generation = try reader.readUInt64()
        let bridgeID = try reader.readUUID()
        let rawPlatform = try reader.readUInt8()
        guard let platform = ParticipantPlatform(rawValue: rawPlatform), platform != .host else {
            throw RelayProtocolError.invalidPlatform(rawPlatform)
        }
        let expires = try reader.readUInt64()
        let count = Int(try reader.readUInt8())
        guard count <= maximumStandbys else { throw RelayProtocolError.tooManyStandbys(count) }
        let standbys = try (0 ..< count).map { _ in try reader.readUUID() }
        guard reader.remaining == 0 else { throw RelayProtocolError.trailingBytes(reader.remaining) }
        return try BridgeAssignmentPayload(generation: generation, bridgeID: bridgeID, bridgePlatform: platform,
                                           leaseExpiresAtMilliseconds: expires, standbyIDs: standbys)
    }
}

/// W5: a far guest's frame carried up the bridge's single control channel to the guide.
/// `version 1 | farParticipantID 16 | lane 1 | length u32 | frame`. The guide treats the contents as
/// advisory (readiness, heartbeat, leave): any admitted member could forge a shared-key frame (DSCN-3).
public struct RelayUpstreamRecord: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let headerLength = 22
    public static let maximumFrameLength = 64 * 1024
    public let farParticipantID: UUID
    public let lane: SessionLane
    public let frame: Data

    public init(farParticipantID: UUID, lane: SessionLane, frame: Data) throws {
        guard frame.count <= Self.maximumFrameLength else { throw RelayProtocolError.frameTooLarge(frame.count) }
        self.farParticipantID = farParticipantID
        self.lane = lane
        self.frame = frame
    }

    public func encode() -> Data {
        var writer = BinaryWriter(capacity: Self.headerLength + frame.count)
        writer.append(Self.version)
        writer.append(farParticipantID)
        writer.append(lane.rawValue)
        writer.append(UInt32(frame.count))
        writer.append(frame)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> RelayUpstreamRecord {
        var reader = BinaryReader(data: data)
        let recordVersion = try reader.readUInt8()
        guard recordVersion == version else { throw RelayProtocolError.invalidVersion(recordVersion) }
        let participant = try reader.readUUID()
        let rawLane = try reader.readUInt8()
        guard let lane = SessionLane(rawValue: rawLane) else { throw RelayProtocolError.invalidLane(rawLane) }
        let length = Int(try reader.readUInt32())
        guard length <= maximumFrameLength else { throw RelayProtocolError.frameTooLarge(length) }
        let frame = try reader.readData(count: length)
        guard reader.remaining == 0 else { throw RelayProtocolError.trailingBytes(reader.remaining) }
        return try RelayUpstreamRecord(farParticipantID: participant, lane: lane, frame: frame)
    }
}

/// The bridge's per-session forwarding state: duplicate suppression across routes, a residence bound
/// for speech, and the latest control snapshot per kind for far guests that join later.
public struct RelayForwarder: Sendable {
    public enum Decision: Equatable, Sendable {
        case forward
        /// Same identity and same bytes seen before (another route, or a failover replay).
        case duplicate
        /// Same identity with different bytes: a protocol error; drop the route that sent it.
        case conflict
        /// Speech held longer than the residence bound; forwarding it would only arrive late.
        case expired
    }

    public struct Identity: Hashable, Sendable {
        public let sessionID: UUID
        public let senderID: UUID
        public let streamID: UUID
        public let sequence: UInt64
    }

    public static let windowSize = 4_096
    public static let audioResidenceMilliseconds: UInt64 = 50

    private var seen: [Identity: Data] = [:]
    private var order: [Identity] = []
    private var snapshots: [SessionMessageKind: (sequence: UInt64, frame: Data)] = [:]

    public init() {}

    /// Decides what to do with one sealed frame (`SealedSessionEnvelope` bytes, optionally inside GOS1),
    /// given when it arrived and when it is about to be forwarded.
    public mutating func admit(_ envelope: SealedSessionEnvelope, frame: Data,
                               receivedAtMilliseconds: UInt64, nowMilliseconds: UInt64) -> Decision {
        let identity = Identity(sessionID: envelope.sessionID, senderID: envelope.senderID,
                                streamID: envelope.streamID, sequence: envelope.sequence)
        let digest = Data(SHA256.hash(data: frame))
        if let known = seen[identity] { return known == digest ? .duplicate : .conflict }
        if envelope.lane == .realtime, nowMilliseconds >= receivedAtMilliseconds,
           nowMilliseconds - receivedAtMilliseconds > Self.audioResidenceMilliseconds {
            return .expired
        }
        seen[identity] = digest
        order.append(identity)
        if order.count > Self.windowSize { seen.removeValue(forKey: order.removeFirst()) }
        if envelope.lane == .control, Self.snapshotKinds.contains(envelope.kind),
           (snapshots[envelope.kind]?.sequence ?? 0) <= envelope.sequence {
            snapshots[envelope.kind] = (envelope.sequence, frame)
        }
        return .forward
    }

    /// Control state a far guest needs on join, replayed locally in sequence order (no bridge bytes).
    public var snapshotFrames: [Data] {
        snapshots.values.sorted { $0.sequence < $1.sequence }.map(\.frame)
    }

    static let snapshotKinds: Set<SessionMessageKind> = [
        .presentationSnapshot, .bearingSnapshot, .targetSnapshot, .visualFocusSnapshot, .bridgeAssignment,
    ]
}
