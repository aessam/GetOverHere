import Testing
import Foundation
@testable import GetOverHere

@MainActor
struct FileShareServiceTests {
    private func makeService() -> (FileShareService, MockTransport) {
        let transport = MockTransport(displayName: "Tester")
        let service = FileShareService(transport: transport)
        return (service, transport)
    }

    @Test func sendFileCallsTransport() {
        let (service, transport) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try? "Hello".write(to: tempFile, atomically: true, encoding: .utf8)

        service.sendFile(at: tempFile, to: peer)

        #expect(transport.sentFiles.count == 1)
        #expect(transport.sentFiles.first?.1 == "test.txt")
        #expect(transport.sentFiles.first?.2.id == peer.id)
    }

    @Test func sendFileAddsToActiveTransfers() {
        let (service, _) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try? "Hello".write(to: tempFile, atomically: true, encoding: .utf8)

        service.sendFile(at: tempFile, to: peer)

        #expect(service.activeTransfers.count == 1)
        #expect(service.activeTransfers.first?.fileName == "test.txt")
        #expect(service.activeTransfers.first?.direction == .sending)
    }

    @Test func receiveFileEventUpdatesState() async throws {
        let (service, transport) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")

        // Simulate receiving notification
        transport.fileContinuation.yield(.receiving(fileName: "photo.jpg", from: peer))
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.activeTransfers.count == 1)
        #expect(service.activeTransfers.first?.fileName == "photo.jpg")
        #expect(service.activeTransfers.first?.direction == .receiving)
    }

    @Test func fileReceivedMovesToCompleted() async throws {
        let (service, transport) = makeService()
        let peer = PeerInfo(id: "peer-1", displayName: "Alice")
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent("photo.jpg")

        transport.fileContinuation.yield(.receiving(fileName: "photo.jpg", from: peer))
        try await Task.sleep(for: .milliseconds(100))

        transport.fileContinuation.yield(.received(fileName: "photo.jpg", from: peer, localURL: fakeURL))
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.activeTransfers.isEmpty)
        #expect(service.receivedFiles.count == 1)
        #expect(service.receivedFiles.first?.localURL == fakeURL)
    }
}
