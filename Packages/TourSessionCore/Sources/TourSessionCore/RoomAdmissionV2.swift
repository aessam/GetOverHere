import CryptoKit
import Foundation

/// Verified possession of a session signing key, not verified human identity.
/// Only a successful v2 admission constructs this value. Discovery keys are not admissions.
public struct AdmittedGuideIdentity: Sendable, Equatable {
    public let sessionID: UUID
    public let guideID: UUID
    public let publicKey: Data

    fileprivate init(sessionID: UUID, guideID: UUID, publicKey: Data) {
        self.sessionID = sessionID
        self.guideID = guideID
        self.publicKey = publicKey
    }
}

/// The media secret is an internal tour credential, never the editable room code or a UI label.
public struct AdmittedRoomCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let mediaSecret: String
    public let guideIdentity: AdmittedGuideIdentity
    public var description: String { "AdmittedRoomCredentials(<redacted>)" }
    public var debugDescription: String { description }

    fileprivate init(mediaSecret: String, guideIdentity: AdmittedGuideIdentity) {
        self.mediaSecret = mediaSecret
        self.guideIdentity = guideIdentity
    }
}

public enum RoomAdmissionV2Error: Error, LocalizedError {
    case incompatibleVersion, wrongGuide, guideChanged

    public var errorDescription: String? {
        switch self {
        case .incompatibleVersion: "This room requires a compatible app version. Update and try again."
        case .wrongGuide: "The room admission did not come from the selected guide."
        case .guideChanged: "The guide identity changed. End this session before joining again."
        }
    }
}

/// Owned by the session coordinator. Reconnection must reuse this pin, not create a new one.
public struct SessionGuidePin: Sendable {
    public private(set) var identity: AdmittedGuideIdentity?

    public init() {}

    public mutating func accept(_ admitted: AdmittedGuideIdentity) throws {
        if let identity {
            guard identity == admitted else { throw RoomAdmissionV2Error.guideChanged }
        } else {
            identity = admitted
        }
    }

    /// Call only when the tour ends or the guest explicitly leaves it, never on route loss.
    public mutating func endSession() { identity = nil }
}

/// GOHR v2 is additive: v1 readers reject its version, and v2 readers reject v1.
/// challenge=103, request=97, reply=183 bytes. The fresh challenge/request transcript binds
/// ECDH/HMAC, the encrypted credential reply, and the guide's signing-key possession proof.
/// Open first contact is TOFU; code possession does not establish a guide's human identity.
public enum RoomAdmissionV2 {
    public static let port = RoomAdmission.port
    public static let challengeSize = 103
    public static let requestSize = 97
    public static let replySize = 183
    private static let magic = Data([0x47, 0x4f, 0x48, 0x52, 2])
    private static let derivationDomain = "GetOverHere/room-admission/v2"
    static let proofDomain = Data("GetOverHere/room-admission-guide/v2\0".utf8)

    public struct Guide: Sendable {
        public let challenge: Data
        private let key: P256.KeyAgreement.PrivateKey
        private let policy: RoomAccessPolicy
        private let signer: GuideFrameSigner

        /// Reuse the same signer for the entire tour and every direct/relayed guide frame.
        public init(sessionID: UUID, policy: RoomAccessPolicy, signer: GuideFrameSigner) throws {
            guard signer.sessionID == sessionID else { throw RoomAdmissionV2Error.wrongGuide }
            key = P256.KeyAgreement.PrivateKey()
            self.policy = policy
            self.signer = signer
            challenge = magic + RoomAdmission.identity(sessionID) + Data([policy.isLocked ? 1 : 0])
                + SessionAuthenticator.randomNonce() + key.publicKey.x963Representation
        }

        public func reply(to request: Data, mediaSecret: String) throws -> Data {
            guard request.count == requestSize, validMediaSecret(Data(mediaSecret.utf8)) else {
                throw RoomAdmissionError.invalidMessage
            }
            let publicKey = Data(request.prefix(65))
            let transcript = challenge + publicKey
            let sharedKey = try RoomAdmission.derive(key, publicKey, policy.secret, transcript, domain: derivationDomain)
            let proof = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: sharedKey))
            guard SessionAuthenticator.securelyMatches(proof, Data(request.suffix(32))) else {
                throw RoomAdmissionError.invalidMessage
            }
            let credentials = Data(mediaSecret.utf8) + RoomAdmission.identity(signer.guideID) + signer.publicKey
            let plaintext = credentials + (try signer.admissionProof(transcript: transcript, credentials: credentials))
            guard let reply = try AES.GCM.seal(plaintext, using: sharedKey, authenticating: transcript).combined,
                  reply.count == replySize else { throw RoomAdmissionError.invalidMessage }
            return reply
        }
    }

    public struct Guest: Sendable {
        public let request: Data
        private let key: SymmetricKey
        private let transcript: Data
        private let sessionID: UUID
        private let expectedGuideID: UUID

        public init(challenge: Data, sessionID: UUID, expectedGuideID: UUID, code: String?) throws {
            guard challenge.count == challengeSize, challenge.prefix(4) == magic.prefix(4) else {
                throw RoomAdmissionError.invalidMessage
            }
            guard challenge[4] == 2 else { throw RoomAdmissionV2Error.incompatibleVersion }
            guard challenge.prefix(21) == magic + RoomAdmission.identity(sessionID), challenge[21] <= 1 else {
                throw RoomAdmissionError.invalidMessage
            }
            let locked = challenge[21] == 1
            guard !locked || code != nil else { throw RoomAdmissionError.locked }
            guard locked || code == nil else { throw RoomAdmissionError.changed }
            let policy = try RoomAccessPolicy(sessionID: sessionID, code: code)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let publicKey = ephemeral.publicKey.x963Representation
            transcript = challenge + publicKey
            key = try RoomAdmission.derive(ephemeral, Data(challenge.suffix(65)), policy.secret, transcript,
                                          domain: derivationDomain)
            self.sessionID = sessionID
            self.expectedGuideID = expectedGuideID
            request = publicKey + Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
        }

        public func open(_ reply: Data) throws -> AdmittedRoomCredentials {
            guard reply.count == replySize else { throw RoomAdmissionError.invalidMessage }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: reply), using: key, authenticating: transcript)
            return try Self.validateCredentials(plaintext, transcript: transcript, sessionID: sessionID,
                                                expectedGuideID: expectedGuideID)
        }

        // Internal boundary permits deterministic tamper tests after AEAD without weakening the public API.
        static func validateCredentials(_ plaintext: Data, transcript: Data, sessionID: UUID,
                                        expectedGuideID: UUID) throws -> AdmittedRoomCredentials {
            guard plaintext.count == 155, validMediaSecret(Data(plaintext.prefix(10))) else {
                throw RoomAdmissionError.invalidMessage
            }
            guard plaintext.subdata(in: 10..<26) == RoomAdmission.identity(expectedGuideID) else {
                throw RoomAdmissionV2Error.wrongGuide
            }
            let publicKey = plaintext.subdata(in: 26..<91)
            let verifier = try GuideFrameVerifier(pinnedPublicKey: publicKey, sessionID: sessionID, guideID: expectedGuideID)
            try verifier.verifyAdmissionProof(Data(plaintext.suffix(64)), transcript: transcript,
                                               credentials: Data(plaintext.prefix(91)))
            let identity = AdmittedGuideIdentity(sessionID: sessionID, guideID: expectedGuideID, publicKey: publicKey)
            return AdmittedRoomCredentials(mediaSecret: String(decoding: plaintext.prefix(10), as: UTF8.self),
                                           guideIdentity: identity)
        }
    }

    private static func validMediaSecret(_ bytes: Data) -> Bool {
        bytes.count == SessionCredential.shortCodeLength && bytes.allSatisfy { SessionCredential.alphabet.contains($0) }
    }
}
