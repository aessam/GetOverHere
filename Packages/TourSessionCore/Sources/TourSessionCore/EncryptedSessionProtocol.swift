import CryptoKit
import Foundation

public enum SessionFrameSecurityError: Error, Equatable, CustomStringConvertible {
    case invalidSealedPayloadLength(Int)
    case authenticationFailed
    case identityReuse(SessionFrameIdentity)
    case replayedFrame(SessionFrameIdentity)

    public var description: String {
        switch self {
        case let .invalidSealedPayloadLength(count):
            "sealed payload is \(count) bytes; minimum is \(SessionFrameCryptography.tagSize)"
        case .authenticationFailed:
            "session frame authentication failed"
        case let .identityReuse(identity):
            "session frame identity was reused: \(identity)"
        case let .replayedFrame(identity):
            "session frame fell outside replay window: \(identity)"
        }
    }
}

public struct SessionFrameIdentity: Hashable, Sendable, CustomStringConvertible {
    public let sessionID: UUID
    public let senderID: UUID
    public let streamID: UUID
    public let lane: SessionLane
    public let kind: SessionMessageKind
    public let flags: UInt16
    public let sequence: UInt64

    public var description: String {
        "session=\(sessionID.uuidString.lowercased()),sender=\(senderID.uuidString.lowercased())," +
            "stream=\(streamID.uuidString.lowercased()),lane=\(lane),kind=\(kind),sequence=\(sequence)"
    }
}

public struct SealedSessionEnvelope: Equatable, Sendable {
    public static let majorVersion: UInt8 = 3
    public static let minorVersion: UInt8 = 0
    public static let headerSize = 70
    static let magic = Data("GOH2".utf8)

    public let minorVersion: UInt8
    public let lane: SessionLane
    public let kind: SessionMessageKind
    public let flags: UInt16
    public let sequence: UInt64
    public let sessionID: UUID
    public let senderID: UUID
    public let streamID: UUID
    public let sealedPayload: Data

    public var identity: SessionFrameIdentity {
        SessionFrameIdentity(
            sessionID: sessionID,
            senderID: senderID,
            streamID: streamID,
            lane: lane,
            kind: kind,
            flags: flags,
            sequence: sequence
        )
    }

    public init(
        minorVersion: UInt8 = Self.minorVersion,
        lane: SessionLane,
        kind: SessionMessageKind,
        flags: UInt16 = 0,
        sequence: UInt64,
        sessionID: UUID,
        senderID: UUID,
        streamID: UUID,
        sealedPayload: Data
    ) throws {
        guard kind.requiredLane == lane else {
            throw SessionProtocolError.wrongLane(kind: kind, actual: lane)
        }
        guard sealedPayload.count >= SessionFrameCryptography.tagSize else {
            throw SessionFrameSecurityError.invalidSealedPayloadLength(sealedPayload.count)
        }
        self.minorVersion = minorVersion
        self.lane = lane
        self.kind = kind
        self.flags = flags
        self.sequence = sequence
        self.sessionID = sessionID
        self.senderID = senderID
        self.streamID = streamID
        self.sealedPayload = sealedPayload
    }

    public func encode() -> Data {
        var data = Self.headerData(
            minorVersion: minorVersion,
            lane: lane,
            kind: kind,
            flags: flags,
            sequence: sequence,
            sessionID: sessionID,
            senderID: senderID,
            streamID: streamID,
            sealedPayloadLength: sealedPayload.count
        )
        data.append(sealedPayload)
        return data
    }

    public static func decode(_ data: Data) throws -> SealedSessionEnvelope {
        var reader = BinaryReader(data: data)
        guard try reader.readData(count: magic.count) == magic else {
            throw SessionProtocolError.invalidMagic
        }
        let major = try reader.readUInt8()
        guard major == majorVersion else {
            throw SessionProtocolError.unsupportedMajorVersion(major)
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
        let streamID = try reader.readUUID()
        let payloadLength = Int(try reader.readUInt32())
        guard reader.remaining == payloadLength else {
            throw SessionProtocolError.invalidPayloadLength(expected: payloadLength, actual: reader.remaining)
        }
        return try SealedSessionEnvelope(
            minorVersion: minor,
            lane: lane,
            kind: kind,
            flags: flags,
            sequence: sequence,
            sessionID: sessionID,
            senderID: senderID,
            streamID: streamID,
            sealedPayload: reader.readData(count: payloadLength)
        )
    }

    static func headerData(
        minorVersion: UInt8 = Self.minorVersion,
        lane: SessionLane,
        kind: SessionMessageKind,
        flags: UInt16,
        sequence: UInt64,
        sessionID: UUID,
        senderID: UUID,
        streamID: UUID,
        sealedPayloadLength: Int
    ) -> Data {
        precondition(sealedPayloadLength <= Int(UInt32.max))
        var writer = BinaryWriter(capacity: headerSize)
        writer.append(magic)
        writer.append(majorVersion)
        writer.append(minorVersion)
        writer.append(lane.rawValue)
        writer.append(kind.rawValue)
        writer.append(flags)
        writer.append(sequence)
        writer.append(sessionID)
        writer.append(senderID)
        writer.append(streamID)
        writer.append(UInt32(sealedPayloadLength))
        return writer.data
    }
}

public enum SessionFrameOpenResult: Equatable, Sendable {
    case opened(SessionEnvelope)
    case duplicate(SessionFrameIdentity)
}

public final class SessionFrameSealer: @unchecked Sendable {
    private struct StreamScope: Hashable {
        let sessionID: UUID
        let senderID: UUID
        let streamID: UUID
    }

    private struct CachedFrame {
        let payloadDigest: Data
        let envelope: SealedSessionEnvelope
    }

    private let lock = NSLock()
    private let applicationKey: Data
    private let protocolMinorVersion: UInt8
    private let cacheLimit: Int
    private var highestSequence: [StreamScope: UInt64] = [:]
    private var cache: [SessionFrameIdentity: CachedFrame] = [:]
    private var cacheOrder: [SessionFrameIdentity] = []

    public init(
        credential: SessionCredential,
        cacheLimit: Int = 256,
        protocolMinorVersion: UInt8 = SealedSessionEnvelope.minorVersion
    ) {
        precondition(cacheLimit > 0)
        applicationKey = SessionFrameCryptography.applicationKey(credential: credential)
        self.cacheLimit = cacheLimit
        self.protocolMinorVersion = protocolMinorVersion
    }

    public func seal(_ envelope: SessionEnvelope, streamID: UUID) throws -> SealedSessionEnvelope {
        lock.lock()
        defer { lock.unlock() }

        let identity = SessionFrameIdentity(
            sessionID: envelope.sessionID,
            senderID: envelope.senderID,
            streamID: streamID,
            lane: envelope.lane,
            kind: envelope.kind,
            flags: envelope.flags,
            sequence: envelope.sequence
        )
        let payloadDigest = Data(SHA256.hash(data: envelope.payload))
        if let cached = cache[identity] {
            guard cached.payloadDigest == payloadDigest else {
                throw SessionFrameSecurityError.identityReuse(identity)
            }
            return cached.envelope
        }

        let scope = StreamScope(
            sessionID: envelope.sessionID,
            senderID: envelope.senderID,
            streamID: streamID
        )
        if let highest = highestSequence[scope], envelope.sequence <= highest {
            throw SessionFrameSecurityError.identityReuse(identity)
        }

        let sealedPayloadLength = envelope.payload.count + SessionFrameCryptography.tagSize
        let authenticatedHeader = SealedSessionEnvelope.headerData(
            minorVersion: protocolMinorVersion,
            lane: envelope.lane,
            kind: envelope.kind,
            flags: envelope.flags,
            sequence: envelope.sequence,
            sessionID: envelope.sessionID,
            senderID: envelope.senderID,
            streamID: streamID,
            sealedPayloadLength: sealedPayloadLength
        )
        let sealedPayload = try SessionFrameCryptography.seal(
            envelope.payload,
            identity: identity,
            authenticatedHeader: authenticatedHeader,
            applicationKey: applicationKey
        )
        let sealed = try SealedSessionEnvelope(
            minorVersion: protocolMinorVersion,
            lane: envelope.lane,
            kind: envelope.kind,
            flags: envelope.flags,
            sequence: envelope.sequence,
            sessionID: envelope.sessionID,
            senderID: envelope.senderID,
            streamID: streamID,
            sealedPayload: sealedPayload
        )
        highestSequence[scope] = envelope.sequence
        cache[identity] = CachedFrame(payloadDigest: payloadDigest, envelope: sealed)
        cacheOrder.append(identity)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return sealed
    }
}

public final class SessionFrameOpener: @unchecked Sendable {
    private struct StreamScope: Hashable {
        let sessionID: UUID
        let senderID: UUID
        let streamID: UUID
    }

    private struct AcceptedFrame {
        let identity: SessionFrameIdentity
        let sealedDigest: Data
    }

    private struct StreamWindow {
        var highestSequence: UInt64
        var accepted: [UInt64: AcceptedFrame]
    }

    private let lock = NSLock()
    private let applicationKey: Data
    private let replayWindow: Int
    private var streamWindows: [StreamScope: StreamWindow] = [:]

    public init(credential: SessionCredential, replayWindow: Int = 4_096) {
        precondition(replayWindow > 0)
        applicationKey = SessionFrameCryptography.applicationKey(credential: credential)
        self.replayWindow = replayWindow
    }

    public func open(_ sealed: SealedSessionEnvelope) throws -> SessionFrameOpenResult {
        lock.lock()
        defer { lock.unlock() }

        let scope = StreamScope(
            sessionID: sealed.sessionID,
            senderID: sealed.senderID,
            streamID: sealed.streamID
        )
        let sealedDigest = Data(SHA256.hash(data: sealed.sealedPayload))
        if let window = streamWindows[scope] {
            let floor = Self.replayFloor(highestSequence: window.highestSequence, windowSize: replayWindow)
            guard sealed.sequence >= floor else {
                throw SessionFrameSecurityError.replayedFrame(sealed.identity)
            }
            if let accepted = window.accepted[sealed.sequence] {
                guard accepted.identity == sealed.identity, accepted.sealedDigest == sealedDigest else {
                    throw SessionFrameSecurityError.identityReuse(sealed.identity)
                }
                return .duplicate(sealed.identity)
            }
        }

        let authenticatedHeader = SealedSessionEnvelope.headerData(
            minorVersion: sealed.minorVersion,
            lane: sealed.lane,
            kind: sealed.kind,
            flags: sealed.flags,
            sequence: sealed.sequence,
            sessionID: sealed.sessionID,
            senderID: sealed.senderID,
            streamID: sealed.streamID,
            sealedPayloadLength: sealed.sealedPayload.count
        )
        let payload = try SessionFrameCryptography.open(
            sealed.sealedPayload,
            identity: sealed.identity,
            authenticatedHeader: authenticatedHeader,
            applicationKey: applicationKey
        )
        let envelope = try SessionEnvelope(
            majorVersion: SealedSessionEnvelope.majorVersion,
            minorVersion: sealed.minorVersion,
            lane: sealed.lane,
            kind: sealed.kind,
            flags: sealed.flags,
            sequence: sealed.sequence,
            sessionID: sealed.sessionID,
            senderID: sealed.senderID,
            payload: payload
        )

        var window = streamWindows[scope] ?? StreamWindow(highestSequence: sealed.sequence, accepted: [:])
        if sealed.sequence > window.highestSequence {
            let oldFloor = Self.replayFloor(highestSequence: window.highestSequence, windowSize: replayWindow)
            let newFloor = Self.replayFloor(highestSequence: sealed.sequence, windowSize: replayWindow)
            if newFloor > oldFloor {
                if newFloor - oldFloor >= UInt64(replayWindow) {
                    window.accepted.removeAll(keepingCapacity: true)
                } else {
                    for sequence in oldFloor ..< newFloor {
                        window.accepted.removeValue(forKey: sequence)
                    }
                }
            }
            window.highestSequence = sealed.sequence
        }
        window.accepted[sealed.sequence] = AcceptedFrame(identity: sealed.identity, sealedDigest: sealedDigest)
        streamWindows[scope] = window
        return .opened(envelope)
    }

    private static func replayFloor(highestSequence: UInt64, windowSize: Int) -> UInt64 {
        let distance = UInt64(windowSize - 1)
        return highestSequence >= distance ? highestSequence - distance : 0
    }
}

enum SessionFrameCryptography {
    static let tagSize = 16
    private static let nonceSize = 12

    static func applicationKey(credential: SessionCredential) -> Data {
        SessionAuthenticator.hmac(
            key: credential.key,
            data: Data("GetOverHere/GOH3/application-payload-key/v1".utf8)
        )
    }

    static func seal(
        _ plaintext: Data,
        identity: SessionFrameIdentity,
        authenticatedHeader: Data,
        applicationKey: Data
    ) throws -> Data {
        let key = SymmetricKey(data: applicationKey)
        let nonce = try AES.GCM.Nonce(data: nonceData(identity: identity, applicationKey: applicationKey))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: authenticatedHeader)
        var result = box.ciphertext
        result.append(box.tag)
        return result
    }

    static func open(
        _ sealedPayload: Data,
        identity: SessionFrameIdentity,
        authenticatedHeader: Data,
        applicationKey: Data
    ) throws -> Data {
        guard sealedPayload.count >= tagSize else {
            throw SessionFrameSecurityError.invalidSealedPayloadLength(sealedPayload.count)
        }
        let split = sealedPayload.count - tagSize
        let key = SymmetricKey(data: applicationKey)
        let nonce = try AES.GCM.Nonce(data: nonceData(identity: identity, applicationKey: applicationKey))
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedPayload.prefix(split),
            tag: sealedPayload.suffix(tagSize)
        )
        do {
            return try AES.GCM.open(box, using: key, authenticating: authenticatedHeader)
        } catch {
            throw SessionFrameSecurityError.authenticationFailed
        }
    }

    private static func nonceData(identity: SessionFrameIdentity, applicationKey: Data) -> Data {
        var writer = BinaryWriter()
        writer.append(Data("GetOverHere/GOH3/frame-nonce/v1".utf8))
        writer.append(identity.sessionID)
        writer.append(identity.senderID)
        writer.append(identity.streamID)
        writer.append(identity.lane.rawValue)
        writer.append(identity.kind.rawValue)
        writer.append(identity.flags)
        writer.append(identity.sequence)
        return Data(SessionAuthenticator.hmac(key: applicationKey, data: writer.data).prefix(nonceSize))
    }
}
