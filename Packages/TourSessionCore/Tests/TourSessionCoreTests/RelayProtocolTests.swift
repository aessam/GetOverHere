import Foundation
import Testing
@testable import TourSessionCore

@Suite("Cross-island relay core (ADR-081)")
struct RelayProtocolTests {
    /// Pinned on both platforms (RelayProtocolTest.kt).
    static let fixture = "assignment=00000000000000076f1c5c6a0000400080000000000000a1020000018bcfe5687b016f1c5c6a0000400080000000000000a2|upstream=016f1c5c6a0000400080000000000000b10200000005474f483201|decisions=forward,duplicate,conflict,expired,forward,forward,forward|snapshots=ec768fa4619a86bd,37e0ac21a9a914ba"

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

    @Test func forwarderWindowForgetsOldestIdentity() throws {
        let session = UUID(), sender = UUID(), stream = UUID()
        func frame(_ sequence: UInt64) throws -> (SealedSessionEnvelope, Data) {
            let envelope = try SealedSessionEnvelope(lane: .control, kind: .heartbeat, sequence: sequence, sessionID: session,
                                                     senderID: sender, streamID: stream, sealedPayload: Data(count: 16))
            return (envelope, envelope.encode())
        }
        var forwarder = RelayForwarder()
        for sequence in 1 ... UInt64(RelayForwarder.windowSize + 1) {
            let (envelope, bytes) = try frame(sequence)
            #expect(forwarder.admit(envelope, frame: bytes, receivedAtMilliseconds: 0, nowMilliseconds: 0) == .forward)
        }
        let (oldest, bytes) = try frame(1)
        #expect(forwarder.admit(oldest, frame: bytes, receivedAtMilliseconds: 0, nowMilliseconds: 0) == .forward,
                "beyond the window the identity is forgotten; the guest's own replay window still rejects it")
        let (recent, recentBytes) = try frame(UInt64(RelayForwarder.windowSize))
        #expect(forwarder.admit(recent, frame: recentBytes, receivedAtMilliseconds: 0, nowMilliseconds: 0) == .duplicate)
        #expect(forwarder.snapshotFrames.isEmpty, "heartbeats are not cached control state")
    }
}
