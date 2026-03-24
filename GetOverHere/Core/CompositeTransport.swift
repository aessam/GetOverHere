import Foundation
import os

/// Runs MultipeerTransport (iOS↔iOS) and BLETransport (all platforms) simultaneously.
/// Both are always active. No bridge mode, no flags. Just two radios.
@Observable
final class DualTransport: TransportProtocol {
    let localPeer: PeerInfo
    private(set) var discoveredPeers: [PeerInfo] = []
    private(set) var connectedPeers: [PeerInfo] = []

    let textMessages: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>
    let controlMessages: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>
    let channelAnnouncements: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>
    let fileHeaders: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>
    let fileChunks: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>
    let audioData: AsyncStream<(Data, PeerInfo)>
    let fileTransfers: AsyncStream<FileTransferEvent>
    let peerEvents: AsyncStream<PeerEvent>

    private let textCont: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>.Continuation
    private let controlCont: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>.Continuation
    private let announceCont: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>.Continuation
    private let fileHeaderCont: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>.Continuation
    private let fileChunkCont: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>.Continuation
    private let audioCont: AsyncStream<(Data, PeerInfo)>.Continuation
    private let fileCont: AsyncStream<FileTransferEvent>.Continuation
    private let peerCont: AsyncStream<PeerEvent>.Continuation

    private let multipeer: MultipeerTransport
    private let ble: BLETransport
    private var tasks: [Task<Void, Never>] = []

    init(displayName: String) {
        self.localPeer = PeerInfo(displayName: displayName)
        self.multipeer = MultipeerTransport(displayName: displayName)
        self.ble = BLETransport(displayName: displayName)

        (textMessages, textCont) = AsyncStream.makeStream()
        (controlMessages, controlCont) = AsyncStream.makeStream()
        (channelAnnouncements, announceCont) = AsyncStream.makeStream()
        (fileHeaders, fileHeaderCont) = AsyncStream.makeStream()
        (fileChunks, fileChunkCont) = AsyncStream.makeStream()
        (audioData, audioCont) = AsyncStream.makeStream()
        (fileTransfers, fileCont) = AsyncStream.makeStream()
        (peerEvents, peerCont) = AsyncStream.makeStream()
    }

    func start() {
        multipeer.start()
        ble.start()
        forward(from: multipeer)
        forward(from: ble)
        Logger.transport.info("DualTransport started (Multipeer + BLE)")
    }

    func stop() {
        multipeer.stop()
        ble.stop()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        discoveredPeers.removeAll()
        connectedPeers.removeAll()
    }

    func invitePeer(_ peer: PeerInfo) {
        multipeer.invitePeer(peer)
        ble.invitePeer(peer)
    }

    func send(_ message: TransportMessage, to peers: [PeerInfo]) throws {
        try multipeer.send(message, to: peers)
        try? ble.send(message, to: peers)
    }

    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws {
        try multipeer.sendAudioData(data, to: peers)
        try? ble.sendAudioData(data, to: peers)
    }

    @discardableResult
    func sendFile(at url: URL, named name: String, to peer: PeerInfo) -> Progress {
        multipeer.sendFile(at: url, named: name, to: peer)
    }

    // MARK: - Forward from a transport into our unified streams

    private func forward(from transport: any TransportProtocol) {
        tasks.append(Task { [weak self] in
            for await item in transport.textMessages { self?.textCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            for await item in transport.controlMessages { self?.controlCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            for await item in transport.channelAnnouncements { self?.announceCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            for await item in transport.fileHeaders { self?.fileHeaderCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            for await item in transport.fileChunks { self?.fileChunkCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            for await item in transport.audioData { self?.audioCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            for await item in transport.fileTransfers { self?.fileCont.yield(item) }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in transport.peerEvents {
                switch event {
                case .discovered(let peer):
                    if !self.discoveredPeers.contains(peer) && !self.connectedPeers.contains(peer) {
                        self.discoveredPeers.append(peer)
                    }
                case .connected(let peer):
                    if !self.connectedPeers.contains(peer) { self.connectedPeers.append(peer) }
                    self.discoveredPeers.removeAll { $0.id == peer.id }
                case .disconnected(let peer):
                    self.connectedPeers.removeAll { $0.id == peer.id }
                case .lost(let peer):
                    self.discoveredPeers.removeAll { $0.id == peer.id }
                case .connecting:
                    break
                }
                self.peerCont.yield(event)
            }
        })
    }
}
