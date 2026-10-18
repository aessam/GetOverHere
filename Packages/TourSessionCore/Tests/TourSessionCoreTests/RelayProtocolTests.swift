import Foundation
import Testing
@testable import TourSessionCore

@Suite("Cross-island relay core (ADR-081)")
struct RelayProtocolTests {
    /// Pinned on both platforms (RelayProtocolTest.kt).
    static let fixture = "assignment=00000000000000076f1c5c6a0000400080000000000000a1020000018bcfe5687b016f1c5c6a0000400080000000000000a2|upstream=016f1c5c6a0000400080000000000000b10200000005474f483201|decisions=forward,duplicate,conflict,expired,forward,forward,forward|snapshots=bearingSnapshot:4,presentationSnapshot:5"

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
}
