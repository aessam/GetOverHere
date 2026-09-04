import CommonCrypto
import CryptoKit
import Foundation

public enum SessionSecurityError: Error, Equatable, CustomStringConvertible {
    case invalidShortCode
    case invalidNonceLength(Int)
    case invalidProofLength(Int)
    case keyStretchFailed(Int32)

    public var description: String {
        switch self {
        case .invalidShortCode:
            "tour code must contain 10 unambiguous letters or digits"
        case let .invalidNonceLength(count):
            "authentication nonce is \(count) bytes; expected \(SessionAuthenticator.nonceSize)"
        case let .invalidProofLength(count):
            "authentication proof is \(count) bytes; expected \(SessionAuthenticator.proofSize)"
        case let .keyStretchFailed(status):
            "tour code stretch failed with CommonCrypto status \(status)"
        }
    }
}

public struct SessionCredential: Equatable, Sendable {
    public static let shortCodeLength = 10
    public static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ".utf8)
    /// PBKDF2-HMAC-SHA256 iteration count; a wire contract shared with the Kotlin core (ADR-042).
    public static let stretchIterations: UInt32 = 600_000
    /// Appended to the session ID wire bytes to form the PBKDF2 salt; a wire contract (ADR-042).
    public static let stretchSaltLabel = "GetOverHere/GOH4/credential-salt/v1"
    /// PBKDF2 output length in bytes; a wire contract (ADR-042).
    public static let stretchedKeySize = 32

    let key: Data

    public static func derive(shortCode: String, sessionID: UUID) throws -> SessionCredential {
        let normalized = normalize(shortCode)
        guard normalized.utf8.count == shortCodeLength,
              normalized.utf8.allSatisfy({ alphabet.contains($0) }) else {
            throw SessionSecurityError.invalidShortCode
        }
        let inputKey = Data(normalized.utf8)
        let salt = sessionID.wireData + Data(stretchSaltLabel.utf8)
        let pseudoRandomKey = try stretch(inputKey: inputKey, salt: salt)
        var expansion = Data("GetOverHere/GOH2/session-key/v1".utf8)
        expansion.append(0x01)
        return SessionCredential(key: SessionAuthenticator.hmac(key: pseudoRandomKey, data: expansion))
    }

    /// PBKDF2-HMAC-SHA256 over the ASCII bytes of an already-normalized tour code.
    static func stretch(inputKey: Data, salt: Data) throws -> Data {
        var derived = Data(count: stretchedKeySize)
        let status = inputKey.withUnsafeBytes { password in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.baseAddress?.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        stretchIterations,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        output.count
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw SessionSecurityError.keyStretchFailed(status)
        }
        return derived
    }

    public static func generateShortCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(bytes: (0 ..< shortCodeLength).map { _ in
            alphabet[Int.random(in: alphabet.indices, using: &generator)]
        }, encoding: .ascii)!
    }

    public static func normalize(_ code: String) -> String {
        String(code.uppercased().filter { !$0.isWhitespace && $0 != "-" })
    }
}

public enum SessionAuthenticator {
    public static let nonceSize = 16
    public static let proofSize = 32

    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< nonceSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func guestProof(
        credential: SessionCredential,
        sessionID: UUID,
        guideID: UUID,
        participantID: UUID,
        requestedLane: SessionLane,
        challengeNonce: Data,
        clientNonce: Data,
        role: SessionRole,
        platform: ParticipantPlatform,
        capabilities: UInt32,
        displayName: String
    ) throws -> Data {
        try validateNonce(challengeNonce)
        try validateNonce(clientNonce)
        var writer = BinaryWriter()
        writer.append(Data("GetOverHere/GOH2/guest-auth/v1".utf8))
        writer.append(sessionID)
        writer.append(guideID)
        writer.append(participantID)
        writer.append(requestedLane.rawValue)
        writer.append(challengeNonce)
        writer.append(clientNonce)
        writer.append(role.rawValue)
        writer.append(platform.rawValue)
        writer.append(capabilities)
        try writer.append(displayName)
        return hmac(key: credential.key, data: writer.data)
    }

    public static func guideProof(
        credential: SessionCredential,
        sessionID: UUID,
        guideID: UUID,
        participantID: UUID,
        requestedLane: SessionLane,
        challengeNonce: Data,
        clientNonce: Data,
        guideNonce: Data
    ) throws -> Data {
        try validateNonce(challengeNonce)
        try validateNonce(clientNonce)
        try validateNonce(guideNonce)
        var writer = BinaryWriter()
        writer.append(Data("GetOverHere/GOH2/guide-auth/v1".utf8))
        writer.append(sessionID)
        writer.append(guideID)
        writer.append(participantID)
        writer.append(requestedLane.rawValue)
        writer.append(challengeNonce)
        writer.append(clientNonce)
        writer.append(guideNonce)
        return hmac(key: credential.key, data: writer.data)
    }

    public static func securelyMatches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func validateNonce(_ nonce: Data) throws {
        guard nonce.count == nonceSize else {
            throw SessionSecurityError.invalidNonceLength(nonce.count)
        }
    }
}

private extension UUID {
    var wireData: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
