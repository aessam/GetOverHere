import Foundation

public enum SessionLane: UInt8, CaseIterable, Sendable {
    case realtime = 1
    case control = 2
    case asset = 3
}

public enum SessionMessageKind: UInt8, CaseIterable, Sendable {
    case hello = 0x01
    case welcome = 0x02
    case heartbeat = 0x03
    case leave = 0x04
    case authChallenge = 0x05
    case audioFrame = 0x10
    case presentationSnapshot = 0x20
    case bearingSnapshot = 0x21
    case targetSnapshot = 0x22
    case visualFocusSnapshot = 0x23
    case assetManifest = 0x30
    case assetChunk = 0x31
    case tourPackManifest = 0x32
    case assetRequest = 0x33
    case assetStatus = 0x34

    public var requiredLane: SessionLane {
        switch self {
        case .audioFrame:
            .realtime
        case .hello, .welcome, .heartbeat, .leave, .authChallenge, .presentationSnapshot, .bearingSnapshot,
             .targetSnapshot, .visualFocusSnapshot:
            .control
        case .assetManifest, .assetChunk, .tourPackManifest, .assetRequest, .assetStatus:
            .asset
        }
    }
}

public enum SessionRole: UInt8, Sendable {
    case guide = 1
    case guest = 2
}

public enum ParticipantPlatform: UInt8, Sendable {
    case iOS = 1
    case android = 2
    case host = 3
}

public enum SessionProtocolError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalidMagic
    case unsupportedMajorVersion(received: UInt8, supported: UInt8)
    case unknownLane(UInt8)
    case unknownMessageKind(UInt8)
    case wrongLane(kind: SessionMessageKind, actual: SessionLane)
    case invalidPayloadLength(expected: Int, actual: Int)
    case invalidRole(UInt8)
    case invalidPlatform(UInt8)
    case invalidUTF8
    case stringTooLong(Int)
    case invalidBoolean(UInt8)
    case invalidBearingReference(UInt8)
    case invalidBearingMilliDegrees(UInt32)
    case invalidVisualMode(UInt8)
    case invalidLatitudeE7(Int32)
    case invalidLongitudeE7(Int32)
    case trailingBytes(Int)
    case invalidSHA256(String)
    case tooManyAssets(Int)
    case invalidAssetKind(UInt8)
    case duplicateAssetID(String)
    case invalidAssetChunk
    case invalidAssetStatus(UInt8)
    case invalidAuthenticationNonceLength(Int)
    case invalidAuthenticationProofLength(Int)
    case unsupportedAwareVersion(UInt8)
    case invalidAwarePort

    public var description: String {
        switch self {
        case .truncated: "truncated data"
        case .invalidMagic: "invalid GOH2 magic"
        case let .unsupportedMajorVersion(received, supported):
            "unsupported major version \(received); this build requires \(supported)"
        case let .unknownLane(raw): "unknown lane \(raw)"
        case let .unknownMessageKind(raw): "unknown message kind \(raw)"
        case let .wrongLane(kind, actual): "\(kind) requires \(kind.requiredLane), got \(actual)"
        case let .invalidPayloadLength(expected, actual):
            "payload length mismatch: expected \(expected), got \(actual)"
        case let .invalidRole(raw): "invalid role \(raw)"
        case let .invalidPlatform(raw): "invalid platform \(raw)"
        case .invalidUTF8: "invalid UTF-8"
        case let .stringTooLong(count): "UTF-8 string is \(count) bytes; maximum is 65535"
        case let .invalidBoolean(raw): "invalid boolean \(raw)"
        case let .invalidBearingReference(raw): "invalid bearing reference \(raw)"
        case let .invalidBearingMilliDegrees(raw): "invalid bearing \(raw) millidegrees"
        case let .invalidVisualMode(raw): "invalid visual mode \(raw)"
        case let .invalidLatitudeE7(raw): "invalid latitude E7 \(raw)"
        case let .invalidLongitudeE7(raw): "invalid longitude E7 \(raw)"
        case let .trailingBytes(count): "payload has \(count) trailing bytes"
        case let .invalidSHA256(value): "invalid lowercase SHA-256: \(value)"
        case let .tooManyAssets(count): "manifest has \(count) assets; maximum is 65535"
        case let .invalidAssetKind(raw): "invalid tour asset kind \(raw)"
        case let .duplicateAssetID(assetID): "duplicate tour asset ID \(assetID)"
        case .invalidAssetChunk: "asset chunk exceeds declared asset length"
        case let .invalidAssetStatus(raw): "invalid asset status \(raw)"
        case let .invalidAuthenticationNonceLength(count):
            "authentication nonce is \(count) bytes; expected \(SessionAuthenticator.nonceSize)"
        case let .invalidAuthenticationProofLength(count):
            "authentication proof is \(count) bytes; expected \(SessionAuthenticator.proofSize)"
        case let .unsupportedAwareVersion(version): "unsupported Wi-Fi Aware version \(version)"
        case .invalidAwarePort: "invalid Wi-Fi Aware lane port"
        }
    }
}

public struct SessionEnvelope: Equatable, Sendable {
    public static let majorVersion: UInt8 = 2
    public static let minorVersion: UInt8 = 1
    public static let headerSize = 54
    private static let magic = Data("GOH2".utf8)

    public let majorVersion: UInt8
    public let minorVersion: UInt8
    public let lane: SessionLane
    public let kind: SessionMessageKind
    public let flags: UInt16
    public let sequence: UInt64
    public let sessionID: UUID
    public let senderID: UUID
    public let payload: Data

    public init(
        majorVersion: UInt8 = Self.majorVersion,
        minorVersion: UInt8 = Self.minorVersion,
        lane: SessionLane,
        kind: SessionMessageKind,
        flags: UInt16 = 0,
        sequence: UInt64,
        sessionID: UUID,
        senderID: UUID,
        payload: Data
    ) throws {
        guard kind.requiredLane == lane else {
            throw SessionProtocolError.wrongLane(kind: kind, actual: lane)
        }
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.lane = lane
        self.kind = kind
        self.flags = flags
        self.sequence = sequence
        self.sessionID = sessionID
        self.senderID = senderID
        self.payload = payload
    }

    public func encode() -> Data {
        var writer = BinaryWriter(capacity: Self.headerSize + payload.count)
        writer.append(Self.magic)
        writer.append(majorVersion)
        writer.append(minorVersion)
        writer.append(lane.rawValue)
        writer.append(kind.rawValue)
        writer.append(flags)
        writer.append(sequence)
        writer.append(sessionID)
        writer.append(senderID)
        writer.append(UInt32(payload.count))
        writer.append(payload)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> SessionEnvelope {
        var reader = BinaryReader(data: data)
        guard try reader.readData(count: magic.count) == magic else {
            throw SessionProtocolError.invalidMagic
        }
        let major = try reader.readUInt8()
        guard major == majorVersion else {
            throw SessionProtocolError.unsupportedMajorVersion(received: major, supported: majorVersion)
        }
        let minor = try reader.readUInt8()
        let laneRaw = try reader.readUInt8()
        guard let lane = SessionLane(rawValue: laneRaw) else {
            throw SessionProtocolError.unknownLane(laneRaw)
        }
        let kindRaw = try reader.readUInt8()
        guard let kind = SessionMessageKind(rawValue: kindRaw) else {
            throw SessionProtocolError.unknownMessageKind(kindRaw)
        }
        let flags = try reader.readUInt16()
        let sequence = try reader.readUInt64()
        let sessionID = try reader.readUUID()
        let senderID = try reader.readUUID()
        let payloadLength = Int(try reader.readUInt32())
        guard reader.remaining == payloadLength else {
            throw SessionProtocolError.invalidPayloadLength(
                expected: payloadLength,
                actual: reader.remaining
            )
        }
        let payload = try reader.readData(count: payloadLength)
        return try SessionEnvelope(
            majorVersion: major,
            minorVersion: minor,
            lane: lane,
            kind: kind,
            flags: flags,
            sequence: sequence,
            sessionID: sessionID,
            senderID: senderID,
            payload: payload
        )
    }
}

public struct HelloPayload: Equatable, Sendable {
    public let role: SessionRole
    public let platform: ParticipantPlatform
    public let capabilities: UInt32
    public let displayName: String
    public let requestedLane: SessionLane
    public let clientNonce: Data
    public let credentialProof: Data

    public init(
        role: SessionRole,
        platform: ParticipantPlatform,
        capabilities: UInt32,
        displayName: String,
        requestedLane: SessionLane,
        clientNonce: Data,
        credentialProof: Data
    ) throws {
        guard clientNonce.count == SessionAuthenticator.nonceSize else {
            throw SessionProtocolError.invalidAuthenticationNonceLength(clientNonce.count)
        }
        guard credentialProof.count == SessionAuthenticator.proofSize else {
            throw SessionProtocolError.invalidAuthenticationProofLength(credentialProof.count)
        }
        self.role = role
        self.platform = platform
        self.capabilities = capabilities
        self.displayName = displayName
        self.requestedLane = requestedLane
        self.clientNonce = clientNonce
        self.credentialProof = credentialProof
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(role.rawValue)
        writer.append(platform.rawValue)
        writer.append(capabilities)
        try writer.append(displayName)
        writer.append(requestedLane.rawValue)
        writer.append(clientNonce)
        writer.append(credentialProof)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> HelloPayload {
        var reader = BinaryReader(data: data)
        let roleRaw = try reader.readUInt8()
        guard let role = SessionRole(rawValue: roleRaw) else {
            throw SessionProtocolError.invalidRole(roleRaw)
        }
        let platformRaw = try reader.readUInt8()
        guard let platform = ParticipantPlatform(rawValue: platformRaw) else {
            throw SessionProtocolError.invalidPlatform(platformRaw)
        }
        let capabilities = try reader.readUInt32()
        let displayName = try reader.readString()
        let requestedLaneRaw = try reader.readUInt8()
        guard let requestedLane = SessionLane(rawValue: requestedLaneRaw) else {
            throw SessionProtocolError.unknownLane(requestedLaneRaw)
        }
        let clientNonce = try reader.readData(count: SessionAuthenticator.nonceSize)
        let credentialProof = try reader.readData(count: SessionAuthenticator.proofSize)
        guard reader.remaining == 0 else {
            throw SessionProtocolError.trailingBytes(reader.remaining)
        }
        return try HelloPayload(
            role: role,
            platform: platform,
            capabilities: capabilities,
            displayName: displayName,
            requestedLane: requestedLane,
            clientNonce: clientNonce,
            credentialProof: credentialProof
        )
    }
}

public struct AuthChallengePayload: Equatable, Sendable {
    public let requestedLane: SessionLane
    public let challengeNonce: Data

    public init(requestedLane: SessionLane, challengeNonce: Data) throws {
        guard challengeNonce.count == SessionAuthenticator.nonceSize else {
            throw SessionProtocolError.invalidAuthenticationNonceLength(challengeNonce.count)
        }
        self.requestedLane = requestedLane
        self.challengeNonce = challengeNonce
    }

    public func encode() -> Data {
        var writer = BinaryWriter()
        writer.append(requestedLane.rawValue)
        writer.append(challengeNonce)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AuthChallengePayload {
        var reader = BinaryReader(data: data)
        let rawLane = try reader.readUInt8()
        guard let lane = SessionLane(rawValue: rawLane) else {
            throw SessionProtocolError.unknownLane(rawLane)
        }
        let nonce = try reader.readData(count: SessionAuthenticator.nonceSize)
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try AuthChallengePayload(requestedLane: lane, challengeNonce: nonce)
    }
}

public struct WelcomePayload: Equatable, Sendable {
    public let requestedLane: SessionLane
    public let guideNonce: Data
    public let credentialProof: Data

    public init(requestedLane: SessionLane, guideNonce: Data, credentialProof: Data) throws {
        guard guideNonce.count == SessionAuthenticator.nonceSize else {
            throw SessionProtocolError.invalidAuthenticationNonceLength(guideNonce.count)
        }
        guard credentialProof.count == SessionAuthenticator.proofSize else {
            throw SessionProtocolError.invalidAuthenticationProofLength(credentialProof.count)
        }
        self.requestedLane = requestedLane
        self.guideNonce = guideNonce
        self.credentialProof = credentialProof
    }

    public func encode() -> Data {
        var writer = BinaryWriter()
        writer.append(requestedLane.rawValue)
        writer.append(guideNonce)
        writer.append(credentialProof)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> WelcomePayload {
        var reader = BinaryReader(data: data)
        let rawLane = try reader.readUInt8()
        guard let lane = SessionLane(rawValue: rawLane) else {
            throw SessionProtocolError.unknownLane(rawLane)
        }
        let guideNonce = try reader.readData(count: SessionAuthenticator.nonceSize)
        let proof = try reader.readData(count: SessionAuthenticator.proofSize)
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try WelcomePayload(requestedLane: lane, guideNonce: guideNonce, credentialProof: proof)
    }
}

struct BinaryWriter {
    private(set) var data: Data

    init(capacity: Int = 0) {
        data = Data(capacity: capacity)
    }

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: Int32) {
        append(UInt32(bitPattern: value))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func append(_ value: UUID) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func append(_ value: String) throws {
        let encoded = Data(value.utf8)
        guard encoded.count <= Int(UInt16.max) else {
            throw SessionProtocolError.stringTooLong(encoded.count)
        }
        append(UInt16(encoded.count))
        append(encoded)
    }
}

struct BinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw SessionProtocolError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return (UInt16(bytes[bytes.startIndex]) << 8)
            | UInt16(bytes[bytes.startIndex + 1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try readData(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt16())
        let bytes = try readData(count: count)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw SessionProtocolError.invalidUTF8
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw SessionProtocolError.truncated
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }
}

public extension Data {
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw SessionProtocolError.truncated
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else {
                throw SessionProtocolError.invalidUTF8
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
