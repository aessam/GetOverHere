import Foundation

// MARK: - Peer Identity

struct PeerInfo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var displayName: String
    var platform: Platform

    enum Platform: String, Codable, Sendable {
        case ios, android
    }

    init(id: String = UUID().uuidString, displayName: String, platform: Platform = .ios) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
    }
}

// MARK: - BLE Commands (control plane)

/// All BLE communication uses these typed commands. No raw bytes, no audio.
enum BLECommand: Codable, Sendable {
    case channelAnnounce(ChannelAnnounce)
    case channelEnded(channelID: String)
    case becomeWiFiHost
    case wifiCredentials(ssid: String, password: String)
    case heartbeat(term: Int, leaderID: String)
    case voteRequest(term: Int, candidateID: String)
    case voteResponse(term: Int, granted: Bool)

    struct ChannelAnnounce: Codable, Sendable {
        let channelID: String
        let channelName: String
        let createdBy: String
        var audioQuality: AudioQuality
        var wifiSSID: String?  // Set once WiFi hotspot is ready
    }
}

enum AudioQuality: String, Codable, Sendable, CaseIterable {
    case standard  // 16kHz mono float32, ~64 KB/s
    case hd        // 44.1kHz stereo float32, ~353 KB/s — WiFi only

    var sampleRate: Double {
        switch self {
        case .standard: 16_000
        case .hd: 44_100
        }
    }

    var channels: Int {
        switch self {
        case .standard: 1
        case .hd: 2
        }
    }

    var label: String {
        switch self {
        case .standard: "Standard (16kHz mono)"
        case .hd: "HD (44.1kHz stereo)"
        }
    }
}

// MARK: - Control Plane Protocol (BLE)

/// Lightweight BLE control plane. Discovery, commands, coordination. NO audio.
protocol ControlPlane: AnyObject {
    var localPeer: PeerInfo { get }
    var connectedPeers: [PeerInfo] { get }
    var commands: AsyncStream<(BLECommand, PeerInfo)> { get }
    var peerEvents: AsyncStream<PeerEvent> { get }

    func start()
    func stop()
    func broadcast(_ command: BLECommand)
    func send(_ command: BLECommand, to peer: PeerInfo)
}

enum PeerEvent: Sendable {
    case discovered(PeerInfo)
    case lost(PeerInfo)
    case connected(PeerInfo)
    case disconnected(PeerInfo)
}

// MARK: - Audio Plane Protocol (Multipeer or WiFi+UDP)

/// High-bandwidth audio transport. Either MultipeerConnectivity or WiFi+UDP.
protocol AudioPlane: AnyObject {
    var isActive: Bool { get }

    /// Start sending audio. Called by the channel creator (speaker).
    func startBroadcasting(channelID: String, quality: AudioQuality)
    /// Send a chunk of captured audio to all listeners.
    func sendAudio(_ data: Data)
    /// Start receiving audio. Called by listeners.
    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void)
    /// Stop everything.
    func stop()
}
