import Foundation
@testable import GetOverHere

final class MockTransport: TransportProtocol {
    let localPeer: PeerInfo
    var discoveredPeers: [PeerInfo] = []
    var connectedPeers: [PeerInfo] = []

    // Stream backing
    let textMessages: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>
    let controlMessages: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>
    let audioData: AsyncStream<(Data, PeerInfo)>
    let fileTransfers: AsyncStream<FileTransferEvent>
    let peerEvents: AsyncStream<PeerEvent>

    // Continuations exposed for test injection
    let textContinuation: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>.Continuation
    let controlContinuation: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>.Continuation
    let audioContinuation: AsyncStream<(Data, PeerInfo)>.Continuation
    let fileContinuation: AsyncStream<FileTransferEvent>.Continuation
    let peerContinuation: AsyncStream<PeerEvent>.Continuation

    // Capture sent messages for assertions
    var sentMessages: [(TransportMessage, [PeerInfo])] = []
    var sentAudioData: [(Data, [PeerInfo])] = []
    var sentFiles: [(URL, String, PeerInfo)] = []

    var startCalled = false
    var stopCalled = false

    init(displayName: String = "TestDevice") {
        self.localPeer = PeerInfo(id: "test-\(displayName)", displayName: displayName)

        (self.textMessages, self.textContinuation) = AsyncStream.makeStream()
        (self.controlMessages, self.controlContinuation) = AsyncStream.makeStream()
        (self.audioData, self.audioContinuation) = AsyncStream.makeStream()
        (self.fileTransfers, self.fileContinuation) = AsyncStream.makeStream()
        (self.peerEvents, self.peerContinuation) = AsyncStream.makeStream()
    }

    func start() { startCalled = true }
    func stop() { stopCalled = true }

    func invitePeer(_ peer: PeerInfo) {
        // Simulate immediate connection
        connectedPeers.append(peer)
        peerContinuation.yield(.connected(peer))
    }

    func send(_ message: TransportMessage, to peers: [PeerInfo]) throws {
        sentMessages.append((message, peers))
    }

    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws {
        sentAudioData.append((data, peers))
    }

    @discardableResult
    func sendFile(at url: URL, named name: String, to peer: PeerInfo) -> Progress {
        sentFiles.append((url, name, peer))
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 100
        return progress
    }

    // MARK: - Test Helpers

    func simulateIncomingText(_ text: String, from peer: PeerInfo) {
        let payload = TransportMessage.TextPayload(
            senderID: peer.id,
            senderName: peer.displayName,
            content: text
        )
        textContinuation.yield((payload, peer))
    }

    func simulateIncomingControl(_ control: TransportMessage.WalkieTalkieControl, from peer: PeerInfo) {
        controlContinuation.yield((control, peer))
    }

    func simulateIncomingAudio(_ data: Data, from peer: PeerInfo) {
        audioContinuation.yield((data, peer))
    }
}
