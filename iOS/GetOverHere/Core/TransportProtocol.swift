import Foundation
import TourSessionCore

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
/// All BLE communication uses these typed commands. No raw bytes, no audio.
/// IMPORTANT: All cases MUST use labeled parameters to avoid Swift's _0 Codable wrapper.
/// See LessonsLearned.md #2.
enum BLECommand: Sendable {
    case channelAnnounce(announce: ChannelAnnounce)
    case channelEnded(channelID: String)
    case becomeWiFiHost
    case wifiCredentials(ssid: String, password: String, hostIP: String?)
    case heartbeat(term: Int, leaderID: String)
    case voteRequest(term: Int, candidateID: String)
    case voteResponse(term: Int, granted: Bool)

    struct ChannelAnnounce: Codable, Sendable {
        let channelID: String
        let channelName: String
        let createdBy: String
        var audioQuality: AudioQuality
        var wifiSSID: String?
        var audioHostIP: String?
    }
}

// Helper structs for cross-platform JSON (proper types, no string-encoding numbers)
private struct ChannelEndedPayload: Codable { let channelID: String }
private struct WiFiCredentialsPayload: Codable { let ssid: String; let password: String; let hostIP: String? }
private struct HeartbeatPayload: Codable { let term: Int; let leaderID: String }
private struct VoteRequestPayload: Codable { let term: Int; let candidateID: String }
private struct VoteResponsePayload: Codable { let term: Int; let granted: Bool }

extension BLECommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case channelAnnounce, channelEnded, becomeWiFiHost, wifiCredentials
        case heartbeat, voteRequest, voteResponse
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .channelAnnounce(let v): try container.encode(v, forKey: .channelAnnounce)
        case .channelEnded(let id): try container.encode(ChannelEndedPayload(channelID: id), forKey: .channelEnded)
        case .becomeWiFiHost: try container.encode(true, forKey: .becomeWiFiHost)
        case .wifiCredentials(let s, let p, let h): try container.encode(WiFiCredentialsPayload(ssid: s, password: p, hostIP: h), forKey: .wifiCredentials)
        case .heartbeat(let t, let l): try container.encode(HeartbeatPayload(term: t, leaderID: l), forKey: .heartbeat)
        case .voteRequest(let t, let c): try container.encode(VoteRequestPayload(term: t, candidateID: c), forKey: .voteRequest)
        case .voteResponse(let t, let g): try container.encode(VoteResponsePayload(term: t, granted: g), forKey: .voteResponse)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? container.decode(ChannelAnnounce.self, forKey: .channelAnnounce) {
            self = .channelAnnounce(announce: v)
        } else if let v = try? container.decode(ChannelEndedPayload.self, forKey: .channelEnded) {
            self = .channelEnded(channelID: v.channelID)
        } else if (try? container.decode(Bool.self, forKey: .becomeWiFiHost)) != nil {
            self = .becomeWiFiHost
        } else if let v = try? container.decode(WiFiCredentialsPayload.self, forKey: .wifiCredentials) {
            self = .wifiCredentials(ssid: v.ssid, password: v.password, hostIP: v.hostIP)
        } else if let v = try? container.decode(HeartbeatPayload.self, forKey: .heartbeat) {
            self = .heartbeat(term: v.term, leaderID: v.leaderID)
        } else if let v = try? container.decode(VoteRequestPayload.self, forKey: .voteRequest) {
            self = .voteRequest(term: v.term, candidateID: v.candidateID)
        } else if let v = try? container.decode(VoteResponsePayload.self, forKey: .voteResponse) {
            self = .voteResponse(term: v.term, granted: v.granted)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown BLECommand"))
        }
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

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    )
    func setSessionEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?)
}

enum AudioSessionEvent: Sendable {
    case joined(ParticipantSession)
    case disconnected(connectionID: String)
}

extension AudioPlane {
    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {}

    func setSessionEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {}
}

// MARK: - Reliable Session Control Transport

enum SessionControlEvent: Sendable {
    case connected
    case guestJoined(ParticipantSession)
    case envelopeReceived(SessionEnvelope)
    case guestDisconnected(participantID: UUID)
    case disconnected
    case failed(String)
}

protocol SessionControlTransport: AnyObject {
    var isActive: Bool { get }
    var hostIP: String? { get set }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    )
    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?)
    func startGuide()
    func startGuest()
    func send(kind: SessionMessageKind, payload: Data)
    func stop()
}

enum SessionAssetEvent: Sendable {
    case connected
    case guestJoined(ParticipantSession)
    case envelopeReceived(SessionEnvelope)
    case guestDisconnected(participantID: UUID)
    case disconnected
    case failed(String)
}

protocol SessionAssetTransport: AnyObject {
    var isActive: Bool { get }
    var hostIP: String? { get set }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    )
    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?)
    func startGuide()
    func startGuest()
    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?)
    func stop()
}
