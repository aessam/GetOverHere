import CryptoKit
import Foundation

public enum RoomAdmissionError: Error, LocalizedError {
    case invalidCode, invalidMessage, locked, changed

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Room code must contain 4–64 printable characters (no spaces)."
        case .invalidMessage: "Room admission failed. Check the code and try again."
        case .locked: "This room is locked. Ask the guide for the room code."
        case .changed: "Room access changed. Select the room again."
        }
    }
}

/// Admission is independent of the immutable GOH4 media credential. Codes are case-sensitive.
public struct RoomAccessPolicy: Sendable {
    public let isLocked: Bool
    let secret: Data

    public static func isValidCode(_ code: String) -> Bool {
        (4...64).contains(code.utf8.count) && code.utf8.allSatisfy { (33...126).contains($0) }
    }

    public init(sessionID: UUID, code: String?) throws {
        isLocked = code != nil
        if let code {
            guard Self.isValidCode(code) else { throw RoomAdmissionError.invalidCode }
            secret = try SessionCredential.stretch(
                inputKey: Data(code.utf8),
                salt: RoomAdmission.identity(sessionID) + Data("GetOverHere/room-code/v1".utf8)
            )
        } else {
            secret = Data(repeating: 0, count: 32)
        }
    }
}

/// Fixed-size, bounded bootstrap: challenge (103), request (97), encrypted reply (38).
/// Fresh P-256 keys protect even open admission from passive LAN observers. Locked rooms
/// mix the stretched code into HKDF and authenticate both sides before disclosing the media secret.
public enum RoomAdmission {
    public static let port: UInt16 = 50003
    public static let challengeSize = 103
    public static let requestSize = 97
    public static let replySize = 38
    private static let magic = Data([0x47, 0x4f, 0x48, 0x52, 1])

    static func identity(_ id: UUID) -> Data {
        var uuid = id.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    public struct Guide: Sendable {
        public let challenge: Data
        private let key: P256.KeyAgreement.PrivateKey
        private let policy: RoomAccessPolicy

        public init(sessionID: UUID, policy: RoomAccessPolicy) {
            key = P256.KeyAgreement.PrivateKey()
            self.policy = policy
            challenge = magic + identity(sessionID) + Data([policy.isLocked ? 1 : 0])
                + SessionAuthenticator.randomNonce() + key.publicKey.x963Representation
        }

        public func reply(to request: Data, sessionCode: String) throws -> Data {
            guard request.count == requestSize,
                  sessionCode.utf8.count == SessionCredential.shortCodeLength,
                  sessionCode.utf8.allSatisfy({ SessionCredential.alphabet.contains($0) }) else {
                throw RoomAdmissionError.invalidMessage
            }
            let publicKey = Data(request.prefix(65))
            let transcript = challenge + publicKey
            let sharedKey = try derive(key, publicKey, policy.secret, transcript)
            let proof = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: sharedKey))
            guard SessionAuthenticator.securelyMatches(proof, Data(request.suffix(32))) else {
                throw RoomAdmissionError.invalidMessage
            }
            return try AES.GCM.seal(Data(sessionCode.utf8), using: sharedKey, authenticating: transcript).combined!
        }
    }

    public struct Guest: Sendable {
        public let request: Data
        private let key: SymmetricKey
        private let transcript: Data

        public init(challenge: Data, sessionID: UUID, code: String?) throws {
            guard challenge.count == challengeSize,
                  challenge.prefix(21) == magic + identity(sessionID),
                  challenge[21] <= 1 else { throw RoomAdmissionError.invalidMessage }
            let locked = challenge[21] == 1
            guard !locked || code != nil else { throw RoomAdmissionError.locked }
            // Never silently downgrade a user's locked-room join to open admission.
            guard locked || code == nil else { throw RoomAdmissionError.changed }
            let policy = try RoomAccessPolicy(sessionID: sessionID, code: code)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let publicKey = ephemeral.publicKey.x963Representation
            transcript = challenge + publicKey
            key = try derive(ephemeral, Data(challenge.suffix(65)), policy.secret, transcript)
            request = publicKey + Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
        }

        public func open(_ reply: Data) throws -> String {
            guard reply.count == replySize else { throw RoomAdmissionError.invalidMessage }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: reply), using: key, authenticating: transcript)
            guard let code = String(data: data, encoding: .ascii),
                  code.utf8.count == SessionCredential.shortCodeLength,
                  code.utf8.allSatisfy({ SessionCredential.alphabet.contains($0) }) else {
                throw RoomAdmissionError.invalidMessage
            }
            return code
        }
    }

    static func derive(_ key: P256.KeyAgreement.PrivateKey, _ peer: Data, _ salt: Data, _ transcript: Data,
                       domain: String = "GetOverHere/room-admission/v1") throws -> SymmetricKey {
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: peer)
        let shared = try key.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data(domain.utf8) + transcript, outputByteCount: 32)
    }
}
