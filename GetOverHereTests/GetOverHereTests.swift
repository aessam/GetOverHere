import Foundation
import Testing
@testable import GetOverHere

@MainActor
struct TransportMessageTests {
    @Test func textPayloadRoundtrip() throws {
        let payload = TransportMessage.TextPayload(
            senderID: "test-id",
            senderName: "Test User",
            content: "Hello, world!"
        )
        let message = TransportMessage.text(payload)

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TransportMessage.self, from: data)

        if case .text(let result) = decoded {
            #expect(result.content == "Hello, world!")
            #expect(result.senderID == "test-id")
            #expect(result.senderName == "Test User")
        } else {
            Issue.record("Expected text message")
        }
    }

    @Test func walkieTalkieControlRoundtrip() throws {
        let control = TransportMessage.WalkieTalkieControl.requestFloor(
            channelID: "ch-1",
            peerID: "peer-1",
            peerName: "Alice"
        )
        let message = TransportMessage.walkieTalkieControl(control)

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TransportMessage.self, from: data)

        if case .walkieTalkieControl(let result) = decoded {
            if case .requestFloor(let channelID, let peerID, let peerName) = result {
                #expect(channelID == "ch-1")
                #expect(peerID == "peer-1")
                #expect(peerName == "Alice")
            } else {
                Issue.record("Expected requestFloor")
            }
        } else {
            Issue.record("Expected walkieTalkieControl")
        }
    }

    @Test func peerInfoEquality() {
        let a = PeerInfo(id: "abc", displayName: "Alice")
        let b = PeerInfo(id: "abc", displayName: "Alice Renamed")
        #expect(a == b) // Same ID = same peer
    }
}
