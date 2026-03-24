import Testing
import SwiftData
@testable import GetOverHere

@MainActor
struct ChatServiceTests {
    private func makeService() -> (ChatService, MockTransport) {
        let transport = MockTransport(displayName: "Tester")
        let service = ChatService(transport: transport)

        // In-memory SwiftData for testing
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: ChatMessage.self, configurations: config)
        service.configure(modelContext: container.mainContext)

        return (service, transport)
    }

    @Test func sendMessageStoresLocally() {
        let (service, transport) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")
        transport.connectedPeers = [peer]

        service.sendMessage("Hello", to: peer)

        let messages = service.messages(for: peer.id)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello")
        #expect(messages.first?.isFromMe == true)
    }

    @Test func sendMessageCallsTransport() {
        let (service, transport) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")

        service.sendMessage("Hello", to: peer)

        #expect(transport.sentMessages.count == 1)
        if case .text(let payload) = transport.sentMessages.first?.0 {
            #expect(payload.content == "Hello")
        } else {
            Issue.record("Expected text message")
        }
    }

    @Test func receiveMessageStoresFromPeer() async throws {
        let (service, transport) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")

        // Simulate incoming message
        transport.simulateIncomingText("Hi there!", from: peer)

        // Give the async listener a moment to process
        try await Task.sleep(for: .milliseconds(100))

        let messages = service.messages(for: peer.id)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hi there!")
        #expect(messages.first?.isFromMe == false)
        #expect(messages.first?.senderName == "Alice")
    }

    @Test func messagesPerPeerAreIsolated() {
        let (service, _) = makeService()
        let alice = PeerInfo(id: "alice", displayName: "Alice")
        let bob = PeerInfo(id: "bob", displayName: "Bob")

        service.sendMessage("To Alice", to: alice)
        service.sendMessage("To Bob", to: bob)

        #expect(service.messages(for: alice.id).count == 1)
        #expect(service.messages(for: bob.id).count == 1)
        #expect(service.messages(for: alice.id).first?.content == "To Alice")
        #expect(service.messages(for: bob.id).first?.content == "To Bob")
    }
}
