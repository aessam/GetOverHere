import Foundation

/// The wired hub protocol only selects fixed application lanes. It never admits
/// a listener, carries a tour secret, or changes signed application frame bytes.
public enum GatewayProtocol {
    public static let servicePort: UInt16 = 50_104
    public static let maximumControlFrameSize = 4_096
    public static let enrollmentLifetimeMilliseconds: UInt64 = 120_000
    public static let heartbeatMilliseconds: UInt64 = 1_000
    public static let heartbeatTimeoutMilliseconds: UInt64 = 3_000
    /// Every validated hub-control descriptor is acknowledged with this byte.
    /// The guide waits for it before sending another descriptor, so a buffered
    /// TCP write alone never counts as evidence that the companion is alive.
    public static let descriptorAcknowledgement: UInt8 = 0
    public static let forwardedAdmissionLimit = 4
    public static let audioResidenceMilliseconds: UInt64 = 50
}

public enum GatewayProtocolError: Error, Equatable, Sendable {
    case malformed, expired, mismatchedPairing, unconfirmed, revoked, wrongGeneration, capacity
}

/// Public enrollment data. Fingerprints are SHA-256 of the complete DER leaf
/// certificate and the tour guide's X9.63 signing public key, respectively.
/// Certificate replacement requires fresh enrollment; no trust-store exception.
public struct GatewayPairingMessage: Equatable, Sendable {
    public enum Role: UInt8, Sendable { case offer = 1, response = 2 }
    public static let qrPrefix = "goh-hub:1:"
    public let role: Role
    public let pairingID: UUID
    public let roomID: UUID
    public let guideID: UUID
    public let expiresAtMilliseconds: UInt64
    public let certificateFingerprint: Data
    public let guideKeyFingerprint: Data
    public let offerCertificateFingerprint: Data
    public let host: String
    public let port: UInt16

    public init(role: Role, pairingID: UUID, roomID: UUID, guideID: UUID,
                expiresAtMilliseconds: UInt64, certificateFingerprint: Data,
                guideKeyFingerprint: Data, offerCertificateFingerprint: Data,
                host: String, port: UInt16) throws {
        guard [pairingID, roomID, guideID].allSatisfy({ $0 != NearbyLaneRequest.metadataRoomID }),
              expiresAtMilliseconds > 0, expiresAtMilliseconds <= UInt64(Int64.max),
              certificateFingerprint.count == 32, guideKeyFingerprint.count == 32,
              offerCertificateFingerprint.count == 32,
              host.utf8.count <= 255,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }) else { throw GatewayProtocolError.malformed }
        switch role {
        case .offer:
            guard !host.isEmpty, port == GatewayProtocol.servicePort,
                  certificateFingerprint == offerCertificateFingerprint else { throw GatewayProtocolError.malformed }
        case .response:
            guard host.isEmpty, port == 0 else { throw GatewayProtocolError.malformed }
        }
        self.role = role; self.pairingID = pairingID; self.roomID = roomID; self.guideID = guideID
        self.expiresAtMilliseconds = expiresAtMilliseconds; self.certificateFingerprint = certificateFingerprint
        self.guideKeyFingerprint = guideKeyFingerprint; self.offerCertificateFingerprint = offerCertificateFingerprint
        self.host = host; self.port = port
    }

    /// Use wall time only for the short enrollment ceremony. Active connection
    /// liveness and queue age use local monotonic time, never this expiry field.
    public func validate(nowMilliseconds: UInt64) throws {
        guard expiresAtMilliseconds > nowMilliseconds,
              expiresAtMilliseconds - nowMilliseconds <= GatewayProtocol.enrollmentLifetimeMilliseconds else {
            throw GatewayProtocolError.expired
        }
    }

    public func validateResponse(to offer: Self, nowMilliseconds: UInt64) throws {
        try validate(nowMilliseconds: nowMilliseconds)
        try offer.validate(nowMilliseconds: nowMilliseconds)
        guard role == .response, offer.role == .offer,
              pairingID == offer.pairingID, roomID == offer.roomID, guideID == offer.guideID,
              expiresAtMilliseconds == offer.expiresAtMilliseconds,
              guideKeyFingerprint == offer.guideKeyFingerprint,
              offerCertificateFingerprint == offer.certificateFingerprint,
              certificateFingerprint != offer.certificateFingerprint else { throw GatewayProtocolError.mismatchedPairing }
    }

    public func encode() -> Data {
        var writer = GatewayWriter(magic: "GHP1")
        writer.byte(role.rawValue); writer.uuid(pairingID); writer.uuid(roomID); writer.uuid(guideID)
        writer.uint64(expiresAtMilliseconds); writer.data.append(certificateFingerprint)
        writer.data.append(guideKeyFingerprint); writer.data.append(offerCertificateFingerprint)
        writer.byte(UInt8(host.utf8.count)); writer.data.append(contentsOf: host.utf8); writer.uint16(port)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> Self {
        var reader = try GatewayReader(data: data, magic: "GHP1", maximum: 415)
        guard let role = Role(rawValue: try reader.byte()) else { throw GatewayProtocolError.malformed }
        let pairing = try reader.uuid(), room = try reader.uuid(), guide = try reader.uuid()
        let expiry = try reader.uint64()
        let certificate = try reader.bytes(32), guideKey = try reader.bytes(32), offer = try reader.bytes(32)
        let hostBytes = try reader.bytes(Int(reader.byte()))
        guard let host = String(data: hostBytes, encoding: .utf8) else { throw GatewayProtocolError.malformed }
        let port = try reader.uint16(); try reader.finish()
        return try Self(role: role, pairingID: pairing, roomID: room, guideID: guide,
                        expiresAtMilliseconds: expiry, certificateFingerprint: certificate,
                        guideKeyFingerprint: guideKey, offerCertificateFingerprint: offer, host: host, port: port)
    }

    public var qrString: String {
        Self.qrPrefix + encode().base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decodeQR(_ text: String) throws -> Self {
        guard text.hasPrefix(qrPrefix), text.utf8.count <= 570 else { throw GatewayProtocolError.malformed }
        let encoded = String(text.dropFirst(qrPrefix.count))
        guard !encoded.isEmpty, encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw GatewayProtocolError.malformed }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64) else { throw GatewayProtocolError.malformed }
        let result = try decode(bytes)
        guard result.qrString == text else { throw GatewayProtocolError.malformed }
        return result
    }
}

public struct GatewayLaneRequest: Equatable, Sendable {
    public enum Lane: UInt8, CaseIterable, Sendable {
        case hubControl = 0, realtime, control, asset, admission
        public var localPort: UInt16? {
            switch self {
            case .hubControl: nil
            case .realtime: 50_000
            case .control: 50_001
            case .asset: 50_002
            case .admission: 50_003
            }
        }
        public init(_ lane: NearbyLaneRequest.Lane) throws {
            guard lane != .metadata, let value = Self(rawValue: lane.rawValue) else { throw GatewayProtocolError.malformed }
            self = value
        }
    }
    public enum Reply: UInt8, Sendable { case accepted = 0, rejected = 1, capacity = 2 }
    public static let size = 45
    public let pairingID: UUID
    public let roomID: UUID
    public let generation: UInt64
    public let lane: Lane

    public init(pairingID: UUID, roomID: UUID, generation: UInt64, lane: Lane) throws {
        guard pairingID != NearbyLaneRequest.metadataRoomID, roomID != NearbyLaneRequest.metadataRoomID,
              generation <= UInt64(Int64.max),
              (lane == .hubControl) == (generation == 0) else { throw GatewayProtocolError.malformed }
        self.pairingID = pairingID; self.roomID = roomID; self.generation = generation; self.lane = lane
    }
    public func encode() -> Data {
        var writer = GatewayWriter(magic: "GHL1")
        writer.uuid(pairingID); writer.uuid(roomID); writer.uint64(generation); writer.byte(lane.rawValue)
        return writer.data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count == size else { throw GatewayProtocolError.malformed }
        var reader = try GatewayReader(data: data, magic: "GHL1", maximum: size)
        let pairing = try reader.uuid(), room = try reader.uuid(), generation = try reader.uint64()
        guard let lane = Lane(rawValue: try reader.byte()) else { throw GatewayProtocolError.malformed }
        try reader.finish()
        return try Self(pairingID: pairing, roomID: room, generation: generation, lane: lane)
    }
}

/// Received only on the mutually authenticated hub-control channel. Original
/// room identity/platform survives forwarding; provider identity is not a guide.
public struct GatewayRoomDescriptor: Equatable, Sendable {
    public let generation: UInt64
    public let recordRevision: UInt64
    public let record: BluetoothRoomRecord
    public let guidePublicKey: Data
    public init(generation: UInt64, recordRevision: UInt64, record: BluetoothRoomRecord, guidePublicKey: Data) throws {
        guard generation > 0, generation <= UInt64(Int64.max),
              recordRevision > 0, recordRevision <= UInt64(Int64.max), record.admissionVersion == 2,
              record.roomID != NearbyLaneRequest.metadataRoomID, record.guideID != NearbyLaneRequest.metadataRoomID,
              guidePublicKey.count == 65, guidePublicKey.first == 4 else { throw GatewayProtocolError.malformed }
        _ = try record.encode()
        self.generation = generation; self.recordRevision = recordRevision; self.record = record
        self.guidePublicKey = guidePublicKey
    }
    public func encode() throws -> Data {
        let recordBytes = try record.encode()
        var writer = GatewayWriter(magic: "GHD1")
        writer.uint64(generation); writer.uint64(recordRevision); writer.uint16(UInt16(recordBytes.count))
        writer.data.append(recordBytes); writer.data.append(guidePublicKey)
        return writer.data
    }
    public static func decode(_ data: Data) throws -> Self {
        var reader = try GatewayReader(data: data, magic: "GHD1", maximum: GatewayProtocol.maximumControlFrameSize)
        let generation = try reader.uint64(), revision = try reader.uint64()
        let recordBytes = try reader.bytes(Int(reader.uint16()))
        let record = try BluetoothRoomRecord.decode(recordBytes)
        let key = try reader.bytes(65); try reader.finish()
        return try Self(generation: generation, recordRevision: revision, record: record, guidePublicKey: key)
    }
}

private struct GatewayWriter {
    var data: Data
    init(magic: String) { data = Data(magic.utf8) }
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint16(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 255)) }
    mutating func uint64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((value >> shift) & 255)) }
    }
    mutating func uuid(_ value: UUID) {
        var tuple = value.uuid; withUnsafeBytes(of: &tuple) { data.append(contentsOf: $0) }
    }
}

private struct GatewayReader {
    private let data: [UInt8]
    private var index = 4
    init(data: Data, magic: String, maximum: Int) throws {
        guard data.count >= 4, data.count <= maximum, data.prefix(4).elementsEqual(magic.utf8) else {
            throw GatewayProtocolError.malformed
        }
        self.data = Array(data)
    }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - index else { throw GatewayProtocolError.malformed }
        defer { index += count }; return Data(data[index..<(index + count)])
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func uint16() throws -> UInt16 { try bytes(2).reduce(0) { ($0 << 8) | UInt16($1) } }
    mutating func uint64() throws -> UInt64 { try bytes(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func uuid() throws -> UUID {
        let b = [UInt8](try bytes(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    func finish() throws { guard index == data.count else { throw GatewayProtocolError.malformed } }
}
