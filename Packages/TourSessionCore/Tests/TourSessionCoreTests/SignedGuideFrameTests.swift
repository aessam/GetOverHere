import Foundation
import Testing
@testable import TourSessionCore

struct SignedGuideFrameTests {
    @Test func signaturePreservesCiphertextAndRejectsEverySingleByteChange() throws {
        let sealed = try TourSessionFixtures.encryptedRealtimeFixture()
        let signer = GuideFrameSigner(sessionID: sealed.sessionID, guideID: sealed.senderID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: sealed.sessionID, guideID: sealed.senderID)
        let signed = try signer.sign(sealed)
        let bytes = signed.encode()
        #expect(try verifier.verify(bytes).encode() == sealed.encode())
        #expect(signed.encode() == bytes)
        let highS = Data(bytes.dropLast(32)) + Data(GuideSignatureEncoding.complement(Array(bytes.suffix(32))))
        #expect(throws: (any Error).self) { try verifier.verify(highS) }
        for index in bytes.indices {
            var changed = bytes; changed[index] ^= 1
            #expect(throws: (any Error).self) { try verifier.verify(changed) }
        }
        for count in 0..<bytes.count {
            #expect(throws: (any Error).self) { try verifier.verify(Data(bytes.prefix(count))) }
        }
        #expect(throws: (any Error).self) { try verifier.verify(bytes + Data([0])) }
        #expect(throws: (any Error).self) { try verifier.verify(sealed.encode()) }
    }

    @Test func pinnedKeyAndGuideAndSessionAreMandatory() throws {
        let sealed = try TourSessionFixtures.encryptedRealtimeFixture()
        let signer = GuideFrameSigner(sessionID: sealed.sessionID, guideID: sealed.senderID)
        let bytes = try signer.sign(sealed).encode()
        let other = GuideFrameSigner(sessionID: sealed.sessionID, guideID: sealed.senderID)
        for (key, session, guide) in [(other.publicKey, sealed.sessionID, sealed.senderID),
            (signer.publicKey, UUID(), sealed.senderID), (signer.publicKey, sealed.sessionID, UUID())] {
            let verifier = try GuideFrameVerifier(pinnedPublicKey: key, sessionID: session, guideID: guide)
            #expect(throws: (any Error).self) { try verifier.verify(bytes) }
        }
        #expect(throws: (any Error).self) {
            try GuideFrameSigner(sessionID: sealed.sessionID, guideID: UUID()).sign(sealed)
        }
    }
}
