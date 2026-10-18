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
    case relayProofMismatch
    case wrongLane
    case notBridgeAssignment
    case assignmentNamesAnotherHost
    case assignmentExpired
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
///
/// Every frame is verified against the guide key pinned at admission before any state changes, so no
/// admitted member can claim a frame identity first or poison the snapshot cache. A verification failure
/// throws; the bridge treats it as a route fault and fails over (CrossIslandDesign D7).
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

    private let verifier: GuideFrameVerifier
    private var seen: [Identity: Data] = [:]
    private var order: [Identity] = []
    private var snapshots: [SessionMessageKind: (sequence: UInt64, frame: Data)] = [:]

    public init(verifier: GuideFrameVerifier) {
        self.verifier = verifier
    }

    /// Decides what to do with one GOS1 guide frame, given when it arrived and when it is about to be
    /// forwarded. Throws when the signature, session or guide does not match the pinned guide.
    public mutating func admit(_ frame: Data, receivedAtMilliseconds: UInt64, nowMilliseconds: UInt64) throws -> Decision {
        let envelope = try verifier.verify(frame)
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

    /// `kind:sequence` of the cached snapshots in replay order (fixtures and diagnostics).
    public var snapshotSummary: [String] {
        snapshots.sorted { $0.value.sequence < $1.value.sequence }.map { "\($0.key):\($0.value.sequence)" }
    }

    static let snapshotKinds: Set<SessionMessageKind> = [
        .presentationSnapshot, .bearingSnapshot, .targetSnapshot, .visualFocusSnapshot, .bridgeAssignment,
    ]
}

/// W6: a far guest accepts an asset chunk sealed by the bridge (not guide-signed) only for a file the
/// guide's authenticated manifest names, and only within that file's length. The whole-file SHA-256 check
/// at completion stays the final gate, the same trust rule as an imported tour pack (ADR-080).
public enum PeerAssetAcceptance {
    public static func accepts(_ chunk: AssetChunkPayload, manifest: TourPackManifestPayload) -> Bool {
        guard let descriptor = manifest.assets.first(where: { $0.sha256 == chunk.sha256 }) else { return false }
        return chunk.totalLength == descriptor.byteLength && !chunk.bytes.isEmpty
            && chunk.offset < descriptor.byteLength
            && UInt64(chunk.bytes.count) <= descriptor.byteLength - chunk.offset
    }
}

/// W4 (ADR-083): what both ends of a relay lane bind. The guest builds it from its own state: the host it chose
/// (its record's `RelayHostAdvert`) and the session/guide it was admitted to. No peer-sent flag selects it.
public struct RelayLaneContext: Equatable, Sendable {
    public let sessionID: UUID
    public let guideID: UUID
    public let host: RelayHostAdvert
    public let participantID: UUID
    public let lane: SessionLane

    public init(sessionID: UUID, guideID: UUID, host: RelayHostAdvert, participantID: UUID, lane: SessionLane) {
        self.sessionID = sessionID; self.guideID = guideID; self.host = host
        self.participantID = participantID; self.lane = lane
    }

    fileprivate func prefix(domain: String) -> BinaryWriter {
        var writer = BinaryWriter()
        writer.append(Data(domain.utf8))
        writer.append(sessionID)
        writer.append(guideID)
        writer.append(host.hostID)
        writer.append(host.bridgeGeneration)
        writer.append(participantID)
        writer.append(lane.rawValue)
        return writer
    }
}

/// W4 (ADR-083): the existing shared-key HMAC challenge/response under relay-only domain labels. Proves
/// membership (the media credential), not the bridge's identity; content stays GOS1-verified end to end.
public enum RelayLaneAuthenticator {
    public static func guestProof(credential: SessionCredential, context: RelayLaneContext, challengeNonce: Data,
                                  clientNonce: Data, role: SessionRole, platform: ParticipantPlatform,
                                  capabilities: UInt32, displayName: String) throws -> Data {
        try validate(challengeNonce, clientNonce)
        var writer = context.prefix(domain: "GetOverHere/GOH2/guest-relay-auth/v1")
        writer.append(challengeNonce)
        writer.append(clientNonce)
        writer.append(role.rawValue)
        writer.append(platform.rawValue)
        writer.append(capabilities)
        try writer.append(displayName)
        return SessionAuthenticator.hmac(key: credential.key, data: writer.data)
    }

    public static func bridgeProof(credential: SessionCredential, context: RelayLaneContext, challengeNonce: Data,
                                   clientNonce: Data, bridgeNonce: Data) throws -> Data {
        try validate(challengeNonce, clientNonce, bridgeNonce)
        var writer = context.prefix(domain: "GetOverHere/GOH2/relay-auth/v1")
        writer.append(challengeNonce)
        writer.append(clientNonce)
        writer.append(bridgeNonce)
        return SessionAuthenticator.hmac(key: credential.key, data: writer.data)
    }

    private static func validate(_ nonces: Data...) throws {
        for nonce in nonces where nonce.count != SessionAuthenticator.nonceSize {
            throw SessionSecurityError.invalidNonceLength(nonce.count)
        }
    }
}

/// W4 (ADR-083, QST-8): the bridge's welcome on a relay lane. It carries the bridge's membership proof and the
/// current guide-signed `bridgeAssignment` frame, which the guest verifies before it uses the lane.
public struct RelayWelcomePayload: Equatable, Sendable {
    public let lane: SessionLane
    public let bridgeNonce: Data
    public let proof: Data
    /// The GOS1 `bridgeAssignment` frame exactly as the guide signed it.
    public let assignmentFrame: Data

    public init(lane: SessionLane, bridgeNonce: Data, proof: Data, assignmentFrame: Data) throws {
        guard bridgeNonce.count == SessionAuthenticator.nonceSize else {
            throw SessionSecurityError.invalidNonceLength(bridgeNonce.count)
        }
        guard proof.count == SessionAuthenticator.proofSize else { throw RelayProtocolError.relayProofMismatch }
        guard assignmentFrame.count <= SignedGuideFrame.maximumSealedSize + 72 else {
            throw RelayProtocolError.frameTooLarge(assignmentFrame.count)
        }
        self.lane = lane; self.bridgeNonce = bridgeNonce; self.proof = proof; self.assignmentFrame = assignmentFrame
    }

    public func encode() -> Data {
        var writer = BinaryWriter(capacity: 53 + assignmentFrame.count)
        writer.append(lane.rawValue)
        writer.append(bridgeNonce)
        writer.append(proof)
        writer.append(UInt32(assignmentFrame.count))
        writer.append(assignmentFrame)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> RelayWelcomePayload {
        var reader = BinaryReader(data: data)
        let rawLane = try reader.readUInt8()
        guard let lane = SessionLane(rawValue: rawLane) else { throw RelayProtocolError.invalidLane(rawLane) }
        let nonce = try reader.readData(count: SessionAuthenticator.nonceSize)
        let proof = try reader.readData(count: SessionAuthenticator.proofSize)
        let length = Int(try reader.readUInt32())
        guard length <= SignedGuideFrame.maximumSealedSize + 72 else { throw RelayProtocolError.frameTooLarge(length) }
        let frame = try reader.readData(count: length)
        guard reader.remaining == 0 else { throw RelayProtocolError.trailingBytes(reader.remaining) }
        return try RelayWelcomePayload(lane: lane, bridgeNonce: nonce, proof: proof, assignmentFrame: frame)
    }

    /// Guest side. Checks the bridge's proof, then the guide's GOS1 signature on the assignment, then that the
    /// assignment names the host and generation the guest chose and is still leased. Returns the assignment.
    public func verify(credential: SessionCredential, context: RelayLaneContext, challengeNonce: Data, clientNonce: Data,
                       guide: GuideFrameVerifier, nowMilliseconds: UInt64) throws -> BridgeAssignmentPayload {
        guard lane == context.lane else { throw RelayProtocolError.wrongLane }
        let expected = try RelayLaneAuthenticator.bridgeProof(credential: credential, context: context,
            challengeNonce: challengeNonce, clientNonce: clientNonce, bridgeNonce: bridgeNonce)
        guard SessionAuthenticator.securelyMatches(expected, proof) else { throw RelayProtocolError.relayProofMismatch }
        let sealed = try guide.verify(assignmentFrame)
        guard sealed.kind == .bridgeAssignment,
              case let .opened(envelope) = try SessionFrameOpener(credential: credential).open(sealed) else {
            throw RelayProtocolError.notBridgeAssignment
        }
        let assignment = try BridgeAssignmentPayload.decode(envelope.payload)
        guard assignment.bridgeID == context.host.hostID, assignment.generation == context.host.bridgeGeneration else {
            throw RelayProtocolError.assignmentNamesAnotherHost
        }
        guard assignment.leaseExpiresAtMilliseconds > nowMilliseconds else { throw RelayProtocolError.assignmentExpired }
        return assignment
    }
}
