import Foundation
import Testing
@testable import TourSessionCore

@Suite("Cross-island relay core (ADR-081)")
struct RelayProtocolTests {
    /// Pinned on both platforms (RelayProtocolTest.kt).
    static let fixture = "assignment=00000000000000076f1c5c6a0000400080000000000000a1020000018bcfe5687b016f1c5c6a0000400080000000000000a2|upstream=016f1c5c6a0000400080000000000000b10200000005474f483201|decisions=forward,duplicate,conflict,expired,forward,forward,forward|snapshots=bearingSnapshot:4,presentationSnapshot:5|guestProof=bcccd0792e4a8622103054af1b2b6276d2a898017f4e809b471419c4ee401ba0|bridgeProof=299bc53d580abcd51daacc95d9d643e92a725a260d7478913a63fbbb7c5de8b3|welcome=0233333333333333333333333333333333299bc53d580abcd51daacc95d9d643e92a725a260d7478913a63fbbb7c5de8b300000004474f5331"

    @Test func pinnedFixture() throws {
        #expect(try TourSessionFixtures.relayFixture() == Self.fixture)
    }

    @Test func bridgeAssignmentRoundtripAndRejections() throws {
        let value = try BridgeAssignmentPayload(generation: .max, bridgeID: UUID(), bridgePlatform: .iOS,
                                                leaseExpiresAtMilliseconds: 1, standbyIDs: [UUID(), UUID()])
        #expect(try BridgeAssignmentPayload.decode(value.encode()) == value)
        #expect(throws: RelayProtocolError.tooManyStandbys(3)) {
            try BridgeAssignmentPayload(generation: 1, bridgeID: UUID(), bridgePlatform: .iOS,
                                        leaseExpiresAtMilliseconds: 1, standbyIDs: [UUID(), UUID(), UUID()])
        }
        var bytes = [UInt8](value.encode())
        bytes[24] = 3 // platform byte: host is never a bridge
        #expect(throws: RelayProtocolError.invalidPlatform(3)) { try BridgeAssignmentPayload.decode(Data(bytes)) }
        #expect(throws: RelayProtocolError.trailingBytes(1)) { try BridgeAssignmentPayload.decode(value.encode() + Data([0])) }
        #expect(throws: (any Error).self) { try BridgeAssignmentPayload.decode(value.encode().dropLast()) }
        #expect(SessionMessageKind.bridgeAssignment.requiredLane == .control)
        #expect(SessionCapabilities.relayHost.rawValue == 1 << 5)
    }

    @Test func upstreamRecordRoundtripAndRejections() throws {
        let value = try RelayUpstreamRecord(farParticipantID: UUID(), lane: .asset, frame: Data(repeating: 7, count: 300))
        #expect(try RelayUpstreamRecord.decode(value.encode()) == value)
        var bytes = [UInt8](value.encode())
        bytes[0] = 2
        #expect(throws: RelayProtocolError.invalidVersion(2)) { try RelayUpstreamRecord.decode(Data(bytes)) }
        bytes = [UInt8](value.encode()); bytes[17] = 9
        #expect(throws: RelayProtocolError.invalidLane(9)) { try RelayUpstreamRecord.decode(Data(bytes)) }
        #expect(throws: RelayProtocolError.frameTooLarge(65_537)) {
            try RelayUpstreamRecord(farParticipantID: UUID(), lane: .control, frame: Data(count: 65_537))
        }
        #expect(throws: RelayProtocolError.trailingBytes(1)) { try RelayUpstreamRecord.decode(value.encode() + Data([0])) }
    }

    private struct Guide {
        let session = UUID(), id = UUID(), stream = UUID()
        let signer: GuideFrameSigner
        init() { signer = GuideFrameSigner(sessionID: session, guideID: id) }
        func verifier() throws -> GuideFrameVerifier {
            try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: id)
        }
        func frame(_ kind: SessionMessageKind, _ sequence: UInt64, by signer: GuideFrameSigner? = nil) throws -> Data {
            try (signer ?? self.signer).sign(SealedSessionEnvelope(lane: kind.requiredLane, kind: kind, sequence: sequence,
                sessionID: session, senderID: id, streamID: stream, sealedPayload: Data(count: 16))).encode()
        }
    }

    @Test func forwarderWindowForgetsOldestIdentity() throws {
        let guide = Guide()
        var forwarder = RelayForwarder(verifier: try guide.verifier())
        for sequence in 1 ... UInt64(RelayForwarder.windowSize + 1) {
            #expect(try forwarder.admit(guide.frame(.heartbeat, sequence), receivedAtMilliseconds: 0, nowMilliseconds: 0) == .forward)
        }
        #expect(try forwarder.admit(guide.frame(.heartbeat, 1), receivedAtMilliseconds: 0, nowMilliseconds: 0) == .forward,
                "beyond the window the identity is forgotten; the guest's own replay window still rejects it")
        // A fresh signature over a remembered identity is different bytes: a conflict, never a silent duplicate.
        let recent = try guide.frame(.heartbeat, UInt64(RelayForwarder.windowSize))
        #expect(try forwarder.admit(recent, receivedAtMilliseconds: 0, nowMilliseconds: 0) == .conflict)
        #expect(forwarder.snapshotFrames.isEmpty, "heartbeats are not cached control state")
    }

    @Test("A frame not signed by the pinned guide changes nothing: no pre-emption, no cache poisoning")
    func unverifiedFramesAreRejectedBeforeAnyState() throws {
        let guide = Guide()
        let member = GuideFrameSigner(sessionID: guide.session, guideID: guide.id) // an admitted member's own key
        var forwarder = RelayForwarder(verifier: try guide.verifier())
        let forged = try guide.frame(.presentationSnapshot, 9, by: member)
        #expect(throws: GuideSignatureError.self) { try forwarder.admit(forged, receivedAtMilliseconds: 0, nowMilliseconds: 0) }
        #expect(forwarder.snapshotFrames.isEmpty)
        let real = try guide.frame(.presentationSnapshot, 9)
        #expect(try forwarder.admit(real, receivedAtMilliseconds: 0, nowMilliseconds: 0) == .forward,
                "the forged copy did not claim the identity")
        #expect(forwarder.snapshotFrames == [real])
        var tampered = [UInt8](real); tampered[tampered.count - 70] ^= 1
        #expect(throws: (any Error).self) { try forwarder.admit(Data(tampered), receivedAtMilliseconds: 0, nowMilliseconds: 0) }
    }

    @Test("Peer-served chunks are accepted only for manifest files and within their length (W6)")
    func peerAssetAcceptance() throws {
        let manifest = try TourPackArchive.read(try TourSessionFixtures.tourPackFixture()).layout.manifest
        let file = manifest.assets[0]
        func chunk(_ hash: String, _ offset: UInt64, _ count: Int, total: UInt64? = nil) throws -> AssetChunkPayload {
            try AssetChunkPayload(sha256: hash, offset: offset, totalLength: total ?? file.byteLength, bytes: Data(count: count))
        }
        #expect(PeerAssetAcceptance.accepts(try chunk(file.sha256, 0, Int(file.byteLength)), manifest: manifest))
        #expect(PeerAssetAcceptance.accepts(try chunk(file.sha256, 4, 3), manifest: manifest))
        #expect(!PeerAssetAcceptance.accepts(try chunk(String(repeating: "a", count: 64), 0, 1, total: 1), manifest: manifest),
                "a hash the manifest does not name")
        #expect(!PeerAssetAcceptance.accepts(try chunk(file.sha256, 0, 1, total: file.byteLength + 1), manifest: manifest),
                "a total length that disagrees with the manifest")
        #expect(!PeerAssetAcceptance.accepts(try chunk(file.sha256, 0, 0), manifest: manifest), "an empty chunk")
    }

    @Test("The relay welcome verifies proof, guide signature, host, generation and lease (W4, ADR-083)")
    func relayWelcomeVerification() throws {
        let guide = Guide()
        let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: guide.session)
        let host = RelayHostAdvert(hostID: UUID(), bridgeGeneration: 3)
        let context = RelayLaneContext(sessionID: guide.session, guideID: guide.id, host: host, participantID: UUID(), lane: .control)
        let challenge = SessionAuthenticator.randomNonce(), client = SessionAuthenticator.randomNonce()
        let bridgeNonce = SessionAuthenticator.randomNonce()
        let sealer = SessionFrameSealer(credential: credential)
        var sequence: UInt64 = 0
        func assignmentFrame(bridge: UUID = host.hostID, generation: UInt64 = 3, expires: UInt64 = 10_000,
                             kind: SessionMessageKind = .bridgeAssignment, signer: GuideFrameSigner? = nil) throws -> Data {
            let payload = try BridgeAssignmentPayload(generation: generation, bridgeID: bridge, bridgePlatform: .android,
                                                      leaseExpiresAtMilliseconds: expires, standbyIDs: []).encode()
            sequence += 1 // the sealer requires increasing sequences per stream
            let envelope = try SessionEnvelope(lane: .control, kind: kind, sequence: sequence,
                                               sessionID: guide.session, senderID: guide.id, payload: payload)
            return try (signer ?? guide.signer).sign(sealer.seal(envelope, streamID: guide.stream)).encode()
        }
        func welcome(_ frame: Data, proofCredential: SessionCredential? = nil, lane: SessionLane = .control) throws -> RelayWelcomePayload {
            let proof = try RelayLaneAuthenticator.bridgeProof(credential: proofCredential ?? credential, context: context,
                challengeNonce: challenge, clientNonce: client, bridgeNonce: bridgeNonce)
            return try RelayWelcomePayload(lane: lane, bridgeNonce: bridgeNonce, proof: proof, assignmentFrame: frame)
        }
        func verify(_ value: RelayWelcomePayload) throws -> BridgeAssignmentPayload {
            try RelayWelcomePayload.decode(value.encode()).verify(credential: credential, context: context, challengeNonce: challenge,
                clientNonce: client, guide: try guide.verifier(), nowMilliseconds: 5_000)
        }
        #expect(try verify(welcome(assignmentFrame())).bridgeID == host.hostID)
        let outsider = try SessionCredential.derive(shortCode: "ZZZZ9999AB", sessionID: guide.session)
        #expect(throws: RelayProtocolError.relayProofMismatch) { try verify(welcome(assignmentFrame(), proofCredential: outsider)) }
        #expect(throws: RelayProtocolError.wrongLane) { try verify(welcome(assignmentFrame(), lane: .asset)) }
        #expect(throws: RelayProtocolError.assignmentNamesAnotherHost) { try verify(welcome(assignmentFrame(bridge: UUID()))) }
        #expect(throws: RelayProtocolError.assignmentNamesAnotherHost) { try verify(welcome(assignmentFrame(generation: 4))) }
        #expect(throws: RelayProtocolError.assignmentExpired) { try verify(welcome(assignmentFrame(expires: 5_000))) }
        #expect(throws: RelayProtocolError.notBridgeAssignment) { try verify(welcome(assignmentFrame(kind: .heartbeat))) }
        let member = GuideFrameSigner(sessionID: guide.session, guideID: guide.id)
        #expect(throws: GuideSignatureError.self) { try verify(welcome(assignmentFrame(signer: member))) }

        let direct = try SessionAuthenticator.guestProof(credential: credential, sessionID: guide.session, guideID: guide.id,
            participantID: context.participantID, requestedLane: .control, challengeNonce: challenge, clientNonce: client,
            role: .guest, platform: .iOS, capabilities: 0, displayName: "G")
        let relay = try RelayLaneAuthenticator.guestProof(credential: credential, context: context, challengeNonce: challenge,
            clientNonce: client, role: .guest, platform: .iOS, capabilities: 0, displayName: "G")
        #expect(direct != relay, "relay proofs use their own domain and are never valid on a direct lane")
    }

    @Test("The guide's bridge choice: eligibility, standbys, generation bumps and lease renewal (P2)")
    func bridgeAuthority() throws {
        #expect(try TourSessionFixtures.bridgeAuthorityFixture() == "iosOnly=none|androidNoRelay=none|firstBridge=g1:03:63000:|noChange=none|standbyJoins=g2:03:65000:04|renew=g2:03:100000:04|bridgeLeft=g3:04:101000:|nobody=none")
    }
}
