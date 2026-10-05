import Foundation
import Testing
@testable import TourSessionCore

struct RoomAdmissionV2Tests {
    private let secret = "23456789AB"

    @Test(arguments: [nil, "1234", "My-Tour!42", String(repeating: "a", count: 64)] as [String?])
    func roundtripBindsMediaCredentialAndSigningIdentity(code: String?) throws {
        let frame = try TourSessionFixtures.encryptedRealtimeFixture()
        let signer = GuideFrameSigner(sessionID: frame.sessionID, guideID: frame.senderID)
        let guide = try RoomAdmissionV2.Guide(sessionID: frame.sessionID,
            policy: RoomAccessPolicy(sessionID: frame.sessionID, code: code), signer: signer)
        let guest = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: frame.sessionID,
            expectedGuideID: frame.senderID, code: code)
        let reply = try guide.reply(to: guest.request, mediaSecret: secret)
        let admitted = try guest.open(reply)
        #expect(guide.challenge.count == 103)
        #expect(guest.request.count == 97)
        #expect(reply.count == 183)
        #expect(admitted.mediaSecret == secret)
        #expect(admitted.guideIdentity.publicKey == signer.publicKey)
        #expect(admitted.guideIdentity.sessionID == frame.sessionID)
        #expect(admitted.guideIdentity.guideID == frame.senderID)
        #expect(!String(describing: admitted).contains(secret))
        #expect(!String(reflecting: admitted).contains(secret))
        let verifier = try GuideFrameVerifier(pinnedPublicKey: admitted.guideIdentity.publicKey,
            sessionID: frame.sessionID, guideID: frame.senderID)
        #expect(try verifier.verify(signer.sign(frame).encode()).encode() == frame.encode())
    }

    @Test func messagesRejectTruncationTrailingBytesAndEveryReplyMutation() throws {
        let session = UUID(), guideID = UUID()
        let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        let guide = try RoomAdmissionV2.Guide(sessionID: session,
            policy: RoomAccessPolicy(sessionID: session, code: nil), signer: signer)
        let guest = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: session,
            expectedGuideID: guideID, code: nil)
        let reply = try guide.reply(to: guest.request, mediaSecret: secret)
        for length in 0..<RoomAdmissionV2.challengeSize {
            #expect(throws: (any Error).self) {
                try RoomAdmissionV2.Guest(challenge: Data(guide.challenge.prefix(length)), sessionID: session,
                                         expectedGuideID: guideID, code: nil)
            }
        }
        #expect(throws: (any Error).self) {
            try RoomAdmissionV2.Guest(challenge: guide.challenge + Data([0]), sessionID: session,
                                     expectedGuideID: guideID, code: nil)
        }
        for length in 0..<RoomAdmissionV2.requestSize {
            #expect(throws: (any Error).self) { try guide.reply(to: Data(guest.request.prefix(length)), mediaSecret: secret) }
        }
        #expect(throws: (any Error).self) { try guide.reply(to: guest.request + Data([0]), mediaSecret: secret) }
        for length in 0..<RoomAdmissionV2.replySize {
            #expect(throws: (any Error).self) { try guest.open(Data(reply.prefix(length))) }
        }
        #expect(throws: (any Error).self) { try guest.open(reply + Data([0])) }
        for index in reply.indices {
            var changed = reply; changed[index] ^= 1
            #expect(throws: (any Error).self) { try guest.open(changed) }
        }
        for index in [0, 4, 21, 38] {
            var changed = guide.challenge; changed[index] = index == 4 ? 1 : 255
            #expect(throws: (any Error).self) {
                try RoomAdmissionV2.Guest(challenge: changed, sessionID: session, expectedGuideID: guideID, code: nil)
            }
        }
    }

    @Test func rejectsDowngradeWrongCodeAndReplayedTranscript() throws {
        let session = UUID(), guideID = UUID()
        let policy = try RoomAccessPolicy(sessionID: session, code: "1234")
        let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        let guide = try RoomAdmissionV2.Guide(sessionID: session, policy: policy, signer: signer)
        let guest = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: session,
            expectedGuideID: guideID, code: "1234")
        let wrong = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: session,
            expectedGuideID: guideID, code: "5678")
        #expect(throws: (any Error).self) { try guide.reply(to: wrong.request, mediaSecret: secret) }
        #expect(throws: (any Error).self) {
            try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: session, expectedGuideID: guideID, code: nil)
        }
        #expect(throws: (any Error).self) {
            try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: UUID(), expectedGuideID: guideID, code: "1234")
        }
        let next = try RoomAdmissionV2.Guide(sessionID: session, policy: policy, signer: signer)
        #expect(throws: (any Error).self) { try next.reply(to: guest.request, mediaSecret: secret) }
        let otherGuest = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: session,
            expectedGuideID: guideID, code: "1234")
        let reply = try guide.reply(to: guest.request, mediaSecret: secret)
        #expect(throws: (any Error).self) { try otherGuest.open(reply) }
        let v1 = RoomAdmission.Guide(sessionID: session, policy: policy)
        #expect(throws: (any Error).self) {
            try RoomAdmissionV2.Guest(challenge: v1.challenge, sessionID: session, expectedGuideID: guideID, code: "1234")
        }
        #expect(throws: (any Error).self) { try RoomAdmission.Guest(challenge: guide.challenge, sessionID: session, code: "1234") }
        let open = try RoomAdmissionV2.Guide(sessionID: session,
            policy: RoomAccessPolicy(sessionID: session, code: nil), signer: signer)
        #expect(throws: (any Error).self) {
            try RoomAdmissionV2.Guest(challenge: open.challenge, sessionID: session, expectedGuideID: guideID, code: "1234")
        }
    }

    @Test func rejectsWrongSelectedGuideAndSignerSession() throws {
        let session = UUID(), guideID = UUID()
        let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        let policy = try RoomAccessPolicy(sessionID: session, code: nil)
        #expect(throws: (any Error).self) { try RoomAdmissionV2.Guide(sessionID: UUID(), policy: policy, signer: signer) }
        let guide = try RoomAdmissionV2.Guide(sessionID: session, policy: policy, signer: signer)
        let guest = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: session,
            expectedGuideID: UUID(), code: nil)
        #expect(throws: (any Error).self) { try guest.open(guide.reply(to: guest.request, mediaSecret: secret)) }
        for invalid in ["", "23456789A", "23456789ABC", "23456789A0", "23456789aB", "23456789é"] {
            #expect(throws: (any Error).self) { try guide.reply(to: guest.request, mediaSecret: invalid) }
        }
    }

    @Test func possessionProofBindsEveryCredentialByteAndFreshTranscript() throws {
        let session = UUID(), guideID = UUID()
        let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        let transcript = Data("test-only-fresh-transcript".utf8)
        let body = Data(secret.utf8) + RoomAdmission.identity(guideID) + signer.publicKey
        let proof = try signer.admissionProof(transcript: transcript, credentials: body)
        let plaintext = body + proof
        let admitted = try RoomAdmissionV2.Guest.validateCredentials(plaintext, transcript: transcript,
            sessionID: session, expectedGuideID: guideID)
        #expect(admitted.guideIdentity.publicKey == signer.publicKey)
        for index in plaintext.indices {
            var changed = plaintext; changed[index] ^= 1
            #expect(throws: (any Error).self) {
                try RoomAdmissionV2.Guest.validateCredentials(changed, transcript: transcript,
                    sessionID: session, expectedGuideID: guideID)
            }
        }
        for changed in [Data(plaintext.dropLast()), plaintext + Data([0]),
            Data(plaintext.dropLast(32)) + Data(GuideSignatureEncoding.complement(Array(plaintext.suffix(32))))] {
            #expect(throws: (any Error).self) {
                try RoomAdmissionV2.Guest.validateCredentials(changed, transcript: transcript,
                    sessionID: session, expectedGuideID: guideID)
            }
        }
        #expect(throws: (any Error).self) {
            try RoomAdmissionV2.Guest.validateCredentials(plaintext, transcript: transcript + Data([0]),
                sessionID: session, expectedGuideID: guideID)
        }
    }

    @Test func pinSurvivesReconnectAndRejectsAnyIdentityChangeUntilExplicitEnd() throws {
        let session = UUID(), guideID = UUID()
        let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        func admit(_ signer: GuideFrameSigner) throws -> AdmittedGuideIdentity {
            let guide = try RoomAdmissionV2.Guide(sessionID: signer.sessionID,
                policy: RoomAccessPolicy(sessionID: signer.sessionID, code: nil), signer: signer)
            let guest = try RoomAdmissionV2.Guest(challenge: guide.challenge, sessionID: signer.sessionID,
                expectedGuideID: signer.guideID, code: nil)
            return try guest.open(guide.reply(to: guest.request, mediaSecret: secret)).guideIdentity
        }
        var pin = SessionGuidePin()
        let original = try admit(signer)
        try pin.accept(original)
        try pin.accept(admit(signer))
        for replacement in [GuideFrameSigner(sessionID: session, guideID: guideID),
            GuideFrameSigner(sessionID: UUID(), guideID: guideID), GuideFrameSigner(sessionID: session, guideID: UUID())] {
            let candidate = try admit(replacement)
            #expect(throws: (any Error).self) { try pin.accept(candidate) }
            #expect(pin.identity == original)
        }
        pin.endSession()
        #expect(pin.identity == nil)
        try pin.accept(admit(GuideFrameSigner(sessionID: UUID(), guideID: UUID())))
        #expect(pin.identity != original)
    }
}
