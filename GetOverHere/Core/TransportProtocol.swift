import Foundation

// MARK: - Peer Identity

struct PeerInfo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var displayName: String

    init(id: String = UUID().uuidString, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

// MARK: - Events

enum PeerEvent: Sendable {
    case discovered(PeerInfo)
    case lost(PeerInfo)
    case connected(PeerInfo)
    case disconnected(PeerInfo)
    case connecting(PeerInfo)
}

enum FileTransferEvent: Sendable {
    case receiving(fileName: String, from: PeerInfo)
    case received(fileName: String, from: PeerInfo, localURL: URL)
    case failed(fileName: String, from: PeerInfo, errorDescription: String)
}

// MARK: - Wire Format

enum DataTag: UInt8, Sendable {
    case message = 1
    case audio = 2
}

// MARK: - Transport Protocol

/// Abstraction over the peer-to-peer transport layer.
/// iOS uses Multipeer Connectivity; Android will use Nearby Connections or BLE.
protocol TransportProtocol: AnyObject {
    var localPeer: PeerInfo { get }
    var discoveredPeers: [PeerInfo] { get }
    var connectedPeers: [PeerInfo] { get }

    var textMessages: AsyncStream<(TransportMessage.TextPayload, PeerInfo)> { get }
    var controlMessages: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)> { get }
    var channelAnnouncements: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)> { get }
    var fileHeaders: AsyncStream<(TransportMessage.FileHeader, PeerInfo)> { get }
    var fileChunks: AsyncStream<(TransportMessage.FileChunk, PeerInfo)> { get }
    var audioData: AsyncStream<(Data, PeerInfo)> { get }
    var fileTransfers: AsyncStream<FileTransferEvent> { get }
    var peerEvents: AsyncStream<PeerEvent> { get }

    func start()
    func stop()
    func invitePeer(_ peer: PeerInfo)
    func send(_ message: TransportMessage, to peers: [PeerInfo]) throws
    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws
    @discardableResult
    func sendFile(at url: URL, named: String, to peer: PeerInfo) -> Progress
}
