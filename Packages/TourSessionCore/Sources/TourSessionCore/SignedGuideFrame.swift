import CryptoKit
import Foundation

public enum GuideSignatureError: Error {
    case invalidFrame, wrongGuide, invalidSignature
}

/// Immutable result of signing once. Forward this value unchanged on every route.
/// No key is accepted from the packet: verification requires an independently pinned key.
public struct SignedGuideFrame: Sendable {
    public static let maximumSealedSize = 65_536
    fileprivate static let magic = Data("GOS1".utf8)
    fileprivate static let domain = Data("GetOverHere/signed-guide/v1\0".utf8)
    private let bytes: Data
    fileprivate init(bytes: Data) { self.bytes = bytes }
    public func encode() -> Data { bytes }
}

public struct GuideFrameSigner: Sendable {
    private let key = P256.Signing.PrivateKey()
    public let sessionID: UUID
    public let guideID: UUID
    public var publicKey: Data { key.publicKey.x963Representation }

    public init(sessionID: UUID, guideID: UUID) {
        self.sessionID = sessionID
        self.guideID = guideID
    }

    public func sign(_ frame: SealedSessionEnvelope) throws -> SignedGuideFrame {
        guard frame.sessionID == sessionID, frame.senderID == guideID else { throw GuideSignatureError.wrongGuide }
        let sealed = frame.encode()
        guard sealed.count <= SignedGuideFrame.maximumSealedSize else { throw GuideSignatureError.invalidFrame }
        let length = UInt32(sealed.count)
        let header = SignedGuideFrame.magic + Data([
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)
        ])
        let body = header + sealed
        let signature = try GuideSignatureEncoding.canonical(key.signature(for: SignedGuideFrame.domain + body).rawRepresentation)
        return SignedGuideFrame(bytes: body + signature)
    }

    /// Same session signing identity, separate domain from media-frame signatures.
    func admissionProof(transcript: Data, credentials: Data) throws -> Data {
        try GuideSignatureEncoding.canonical(key.signature(
            for: RoomAdmissionV2.proofDomain + transcript + credentials
        ).rawRepresentation)
    }
}

public struct GuideFrameVerifier: Sendable {
    private let key: P256.Signing.PublicKey
    private let sessionID: UUID
    private let guideID: UUID

    /// Call only with a key obtained through the approved direct-admission/QR bootstrap.
    /// Construction validates the key, but does not authenticate where the caller obtained it.
    public init(pinnedPublicKey: Data, sessionID: UUID, guideID: UUID) throws {
        guard pinnedPublicKey.count == 65, pinnedPublicKey.first == 4 else { throw GuideSignatureError.invalidFrame }
        key = try P256.Signing.PublicKey(x963Representation: pinnedPublicKey)
        self.sessionID = sessionID
        self.guideID = guideID
    }

    public func verify(_ packet: Data) throws -> SealedSessionEnvelope {
        guard (158...(SignedGuideFrame.maximumSealedSize + 72)).contains(packet.count),
              packet.prefix(4) == SignedGuideFrame.magic else { throw GuideSignatureError.invalidFrame }
        let length = packet.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) == packet.count - 72 else { throw GuideSignatureError.invalidFrame }
        let body = Data(packet.dropLast(64))
        let raw = Data(packet.suffix(64))
        guard try GuideSignatureEncoding.canonical(raw) == raw else { throw GuideSignatureError.invalidSignature }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        guard key.isValidSignature(signature, for: SignedGuideFrame.domain + body) else {
            throw GuideSignatureError.invalidSignature
        }
        // Verify the signature before decoding ciphertext or invoking the existing AEAD opener.
        let sealed = try SealedSessionEnvelope.decode(Data(body.dropFirst(8)))
        guard sealed.sessionID == sessionID, sealed.senderID == guideID else { throw GuideSignatureError.wrongGuide }
        return sealed
    }

    func verifyAdmissionProof(_ raw: Data, transcript: Data, credentials: Data) throws {
        guard try GuideSignatureEncoding.canonical(raw) == raw else { throw GuideSignatureError.invalidSignature }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        guard key.isValidSignature(signature, for: RoomAdmissionV2.proofDomain + transcript + credentials) else {
            throw GuideSignatureError.invalidSignature
        }
    }
}

/// Canonical low-S ECDSA prevents a forwarder from changing a valid packet's signature bytes.
enum GuideSignatureEncoding {
    static let order: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51
    ]
    static func complement(_ scalar: [UInt8]) -> [UInt8] {
        precondition(scalar.count == 32)
        var result = order
        var borrow = 0
        for index in (0..<32).reversed() {
            let value = Int(order[index]) - Int(scalar[index]) - borrow
            result[index] = UInt8(truncatingIfNeeded: value)
            borrow = value < 0 ? 1 : 0
        }
        return result
    }
    static func canonical(_ signature: Data) throws -> Data {
        guard signature.count == 64 else { throw GuideSignatureError.invalidSignature }
        let r = Array(signature.prefix(32)), s = Array(signature.suffix(32))
        guard r.contains(where: { $0 != 0 }), s.contains(where: { $0 != 0 }),
              r.lexicographicallyPrecedes(order), s.lexicographicallyPrecedes(order) else {
            throw GuideSignatureError.invalidSignature
        }
        let other = complement(s)
        return Data(r + (other.lexicographicallyPrecedes(s) ? other : s))
    }
}
