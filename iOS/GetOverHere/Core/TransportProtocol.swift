import Foundation
import TourSessionCore

/// Production sessions must explicitly install admission-bound guide authority. The unsigned
/// profile exists only for standalone compatibility fixtures and is never selected automatically.
nonisolated enum SessionGuideAuthentication: Sendable {
    case unconfigured
    case guide(GuideFrameSigner)
    case guest(GuideFrameVerifier)
    case legacyFixture

    func requireGuide(sessionID: UUID, guideID: UUID) throws {
        switch self {
        case let .guide(signer):
            guard signer.sessionID == sessionID, signer.guideID == guideID else {
                throw GuideSignatureError.wrongGuide
            }
        case .legacyFixture: break
        case .unconfigured, .guest: throw SessionGuideAuthenticationError.notConfigured
        }
    }

    func requireGuest() throws {
        switch self {
        case .guest, .legacyFixture: break
        case .unconfigured, .guide: throw SessionGuideAuthenticationError.notConfigured
        }
    }

    func requireSharedGuideProducer(hasMultipleOwners: Bool) throws {
        switch self {
        case .guide:
            guard !hasMultipleOwners else { throw SessionGuideAuthenticationError.independentGuideFanoutUnavailable }
        case .legacyFixture: break
        case .unconfigured, .guest: throw SessionGuideAuthenticationError.notConfigured
        }
    }

    func encodeGuideFrame(_ sealed: SealedSessionEnvelope) throws -> Data {
        switch self {
        case let .guide(signer): try signer.sign(sealed).encode()
        case .legacyFixture: sealed.encode()
        case .unconfigured, .guest: throw SessionGuideAuthenticationError.notConfigured
        }
    }

    func decodeGuideFrame(_ bytes: Data) throws -> SealedSessionEnvelope {
        switch self {
        case let .guest(verifier): try verifier.verify(bytes)
        case .legacyFixture: try SealedSessionEnvelope.decode(bytes)
        case .unconfigured, .guide: throw SessionGuideAuthenticationError.notConfigured
        }
    }
}

nonisolated enum SessionGuideAuthenticationError: LocalizedError {
    case notConfigured
    case independentGuideFanoutUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "The admitted guide identity is not configured. Rejoin the room."
        case .independentGuideFanoutUnavailable: "Signed guide frames require a shared producer across routes."
        }
    }
}

/// Atomic admission to a native application lane, after hello proof and before welcome.
/// A reconnect may overlap its own old socket; it cannot evict another participant.
nonisolated final class SessionParticipantSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [UUID: UUID] = [:]
    private let limit: Int

    init(limit: Int = SessionCapacityPolicy.listenerLimit) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire(participantID: UUID, connectionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if let existing = owners[connectionID] {
            guard existing == participantID else { throw SessionParticipantCapacityError.rejected }
            return
        }
        let participants = Set(owners.values)
        guard participants.contains(participantID) || participants.count < limit else {
            throw SessionParticipantCapacityError.full
        }
        owners[connectionID] = participantID
    }

    func release(_ connectionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        owners.removeValue(forKey: connectionID)
    }

    var participantCount: Int {
        lock.lock(); defer { lock.unlock() }
        return Set(owners.values).count
    }
}

nonisolated enum SessionParticipantCapacityError: Error {
    case full, rejected
}

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
    case channelUnavailable(channelID: String)
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
        var roomAdmissionVersion: Int? = nil
        var isRoomLocked: Bool? = nil
    }
}

// Helper structs for cross-platform JSON (proper types, no string-encoding numbers)
private struct ChannelEndedPayload: Codable { let channelID: String }
private struct ChannelUnavailablePayload: Codable { let channelID: String }
private struct WiFiCredentialsPayload: Codable { let ssid: String; let password: String; let hostIP: String? }
private struct HeartbeatPayload: Codable { let term: Int; let leaderID: String }
private struct VoteRequestPayload: Codable { let term: Int; let candidateID: String }
private struct VoteResponsePayload: Codable { let term: Int; let granted: Bool }

extension BLECommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case channelAnnounce, channelUnavailable, channelEnded, becomeWiFiHost, wifiCredentials
        case heartbeat, voteRequest, voteResponse
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .channelAnnounce(let v): try container.encode(v, forKey: .channelAnnounce)
        case .channelUnavailable(let id): try container.encode(ChannelUnavailablePayload(channelID: id), forKey: .channelUnavailable)
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
        } else if let v = try? container.decode(ChannelUnavailablePayload.self, forKey: .channelUnavailable) {
            self = .channelUnavailable(channelID: v.channelID)
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
    case standard  // 16 kHz mono PCM16 codec input, ~32 KB/s before encoding
    case hd        // 44.1 kHz stereo PCM16 codec input, ~176 KB/s before encoding

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
enum BluetoothDiscoveryMode { case off, browsing, advertising }

protocol ControlPlane: AnyObject {
    var localPeer: PeerInfo { get }
    var connectedPeers: [PeerInfo] { get }
    var commands: AsyncStream<(BLECommand, PeerInfo)> { get }
    var peerEvents: AsyncStream<PeerEvent> { get }

    func start()
    func stop()
    func broadcast(_ command: BLECommand)
    func send(_ command: BLECommand, to peer: PeerInfo)
    func setBluetoothDiscoveryMode(_ mode: BluetoothDiscoveryMode)
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
    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication)

    /// Start sending audio. Called by the channel creator (speaker). Synchronous and throwing
    /// (FND-2): the guide commits state only after the lane is listening.
    func startBroadcasting(channelID: String, quality: AudioQuality) throws
    /// Send a chunk of captured audio to all listeners.
    func sendAudio(_ data: Data)
    /// Start receiving audio. Called by listeners.
    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void)
    /// Stop everything.
    func stop()
    /// Stop and erase session credentials. Use only when the logical session ends.
    func clearSession()

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
    case versionMismatch(remoteMajor: UInt8, localMajor: UInt8)
    case authenticationFailed(String)
    case failed(String)
}

/// Why the realtime lane could not start listening for guests (FND-2).
enum AudioPlaneStartError: LocalizedError, Equatable {
    case sessionNotConfigured
    case noNativeEncoder
    case socketFailed(String)
    case bindFailed(String)
    case listenFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotConfigured: "Audio lane: session is not configured"
        case .noNativeEncoder: "Audio lane: no native realtime encoder is available"
        case let .socketFailed(message): "Audio lane: socket failed: \(message)"
        case let .bindFailed(message): "Audio lane: bind failed: \(message)"
        case let .listenFailed(message): "Audio lane: listen failed: \(message)"
        }
    }
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
    case versionMismatch(remoteMajor: UInt8, localMajor: UInt8)
    /// The sealed handshake frame failed AEAD authentication or the guide proof mismatched; never an EOF.
    case credentialRejected(String)
    case failed(String)
}

protocol SessionControlTransport: AnyObject {
    var isActive: Bool { get }
    var hostIP: String? { get set }
    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication)

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    )
    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?)
    /// Synchronous and throwing (FND-2): unconfigured or bind/listen failures surface to the caller.
    func startGuide() throws
    func startGuest()
    func send(kind: SessionMessageKind, payload: Data)
    /// Enqueues one authenticated leave frame to every connected peer and waits off the calling
    /// actor for delivery or the 2 s deadline; never blocks the caller's thread (FND-8).
    func sendLeave() async
    func stop()
    func clearSession()
}

enum SessionAssetEvent: Sendable {
    case connected
    case guestJoined(ParticipantSession)
    case envelopeReceived(SessionEnvelope)
    case guestDisconnected(participantID: UUID)
    case disconnected
    case versionMismatch(remoteMajor: UInt8, localMajor: UInt8)
    case credentialRejected(String)
    case failed(String)
}

protocol SessionAssetTransport: AnyObject {
    var isActive: Bool { get }
    var hostIP: String? { get set }
    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication)

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    )
    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?)
    /// Synchronous and throwing (FND-2): unconfigured or bind/listen failures surface to the caller.
    func startGuide() throws
    func startGuest()
    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?)
    func stop()
    func clearSession()
}
