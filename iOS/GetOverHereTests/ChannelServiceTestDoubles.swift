import Foundation
import TourSessionCore
@testable import GetOverHere

/// Shared ChannelService-level doubles (G4, DSCN-23). They record every lane call and expose `emit`
/// so a simulator test can drive the product state machine without sockets, Bonjour, or AVAudioEngine.
/// G5 reuses `LifecycleAssetTransport` for its transfer tests. Names avoid the file-private
/// `RecordingAudioPlane` / `RecordingControlTransport` in the hybrid and presentation suites.

enum LifecycleLaneError: LocalizedError {
    case bind(String)

    var errorDescription: String? {
        switch self {
        case let .bind(message): message
        }
    }
}

nonisolated final class LifecycleRoomAdmission: RoomAdmissionInterface, Sendable {
    func start(sessionID: UUID, sessionCode: String) throws {}
    func update(policy: RoomAccessPolicy) throws {}
    func stop() {}
    func join(host: String, sessionID: UUID, code: String?) throws -> String {
        throw RoomAdmissionError.invalidMessage
    }
}

@MainActor
final class LifecycleControlPlane: ControlPlane {
    private(set) var bluetoothMode: BluetoothDiscoveryMode = .off
    func setBluetoothDiscoveryMode(_ mode: BluetoothDiscoveryMode) { bluetoothMode = mode }
    let localPeer: PeerInfo
    var connectedPeers: [PeerInfo] = []
    let commands: AsyncStream<(BLECommand, PeerInfo)>
    let peerEvents: AsyncStream<PeerEvent>
    private let commandContinuation: AsyncStream<(BLECommand, PeerInfo)>.Continuation
    private let peerEventContinuation: AsyncStream<PeerEvent>.Continuation
    private(set) var broadcasts: [BLECommand] = []
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(localPeer: PeerInfo? = nil) {
        self.localPeer = localPeer ?? PeerInfo(displayName: "Local")
        // Built once: NetworkCoordinator iterates `commands` a single time.
        (commands, commandContinuation) = AsyncStream.makeStream()
        (peerEvents, peerEventContinuation) = AsyncStream.makeStream()
    }

    var announcedChannelIDs: [String] {
        broadcasts.compactMap {
            if case let .channelAnnounce(announce) = $0 { announce.channelID } else { nil }
        }
    }

    var endedChannelIDs: [String] {
        broadcasts.compactMap {
            if case let .channelEnded(channelID) = $0 { channelID } else { nil }
        }
    }

    func start() { startCalls += 1 }
    func stop() { stopCalls += 1 }
    func broadcast(_ command: BLECommand) { broadcasts.append(command) }
    func send(_ command: BLECommand, to peer: PeerInfo) { broadcasts.append(command) }

    /// Delivers a discovery command as if Bonjour had resolved it from `peer` (a guide by default).
    func emit(_ command: BLECommand, from peer: PeerInfo? = nil) {
        commandContinuation.yield((command, peer ?? PeerInfo(displayName: "Guide", platform: .ios)))
    }
}

@MainActor
final class LifecycleAudioPlane: AudioPlane {
    var isActive = false
    private(set) var startBroadcastingCalls = 0
    private(set) var startListeningCalls = 0
    private(set) var stopCalls = 0
    var clearSessionCalls = 0
    private(set) var configureCalls = 0
    private(set) var sent: [Data] = []
    var startBroadcastingError: (any Error)?
    private var handler: (@Sendable (AudioSessionEvent) -> Void)?

    func startBroadcasting(channelID: String, quality: AudioQuality) throws {
        startBroadcastingCalls += 1
        if let startBroadcastingError { throw startBroadcastingError }
        isActive = true
    }

    func sendAudio(_ data: Data) { sent.append(data) }

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        startListeningCalls += 1
        isActive = true
    }

    func stop() {
        stopCalls += 1
        isActive = false
    }

    func clearSession() {
        clearSessionCalls += 1
        isActive = false
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        configureCalls += 1
    }

    func setSessionEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {
        self.handler = handler
    }

    func emit(_ event: AudioSessionEvent) {
        guard let handler else {
            fatalError("audio session handler is not installed")
        }
        handler(event)
    }
}

@MainActor
final class LifecycleControlTransport: SessionControlTransport {
    var configureCalls = 0
    var isActive = false
    var hostIP: String?
    private(set) var startGuideCalls = 0
    private(set) var startGuestCalls = 0
    private(set) var stopCalls = 0
    var clearSessionCalls = 0
    private(set) var startGuestHostIPs: [String] = []
    private(set) var sent: [(kind: SessionMessageKind, payload: Data)] = []
    var startGuideError: (any Error)?
    var onStartGuest: (() -> Void)?
    /// When set, `sendLeave()` suspends until `resumeLeave()`, so a test can observe the state
    /// between End Tour and the deferred lane teardown.
    var holdLeave = false
    private var leaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var leaveFlushCount = 0
    /// Set when the synchronous, main-thread-blocking `.leave` path was used.
    private(set) var blockingLeaveUsed = false
    private var handler: (@Sendable (SessionControlEvent) -> Void)?

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) { configureCalls += 1 }

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() throws {
        startGuideCalls += 1
        if let startGuideError { throw startGuideError }
        isActive = true
    }

    func startGuest() {
        startGuestCalls += 1
        startGuestHostIPs.append(hostIP ?? "<none>")
        isActive = true
        onStartGuest?()
    }

    func send(kind: SessionMessageKind, payload: Data) {
        if kind == .leave { blockingLeaveUsed = true }
        sent.append((kind, payload))
    }

    func sendLeave() async {
        leaveFlushCount += 1
        if holdLeave {
            await withCheckedContinuation { continuation in
                leaveContinuation = continuation
            }
        }
        sent.append((.leave, Data()))
    }

    func resumeLeave() {
        leaveContinuation?.resume()
        leaveContinuation = nil
    }

    func stop() {
        stopCalls += 1
        isActive = false
    }

    func clearSession() {
        clearSessionCalls += 1
        isActive = false
    }

    func emit(_ event: SessionControlEvent) {
        guard let handler else {
            fatalError("control event handler is not installed")
        }
        handler(event)
    }
}

@MainActor
final class LifecycleAssetTransport: SessionAssetTransport {
    var configureCalls = 0
    struct Sent {
        let kind: SessionMessageKind
        let payload: Data
        let to: UUID?
    }

    var isActive = false
    var hostIP: String?
    private(set) var startGuideCalls = 0
    private(set) var startGuestCalls = 0
    private(set) var stopCalls = 0
    var clearSessionCalls = 0
    private(set) var sent: [Sent] = []
    var startGuideError: (any Error)?
    private var handler: (@Sendable (SessionAssetEvent) -> Void)?

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) { configureCalls += 1 }

    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() throws {
        startGuideCalls += 1
        if let startGuideError { throw startGuideError }
        isActive = true
    }

    func startGuest() {
        startGuestCalls += 1
        isActive = true
    }

    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        sent.append(Sent(kind: kind, payload: payload, to: participantID))
    }

    func stop() {
        stopCalls += 1
        isActive = false
    }

    func clearSession() {
        clearSessionCalls += 1
        isActive = false
    }

    func emit(_ event: SessionAssetEvent) {
        guard let handler else {
            fatalError("asset event handler is not installed")
        }
        handler(event)
    }
}

@MainActor
final class FakeAudioEngine: AudioEngineInterface {
    var listenerOutput: ListenerOutput = .privateAudio
    private(set) var isCapturing = false
    private(set) var isPlaying = false
    private(set) var startCaptureCalls = 0
    var startCaptureError: (any Error)?
    var onStartCapture: (() -> Void)?
    /// Continuation of the live capture stream; a test finishes it to simulate the engine tearing
    /// the pipeline down (interruption or a failed converter rebuild).
    private(set) var captureContinuation: AsyncStream<Data>.Continuation?
    private(set) var played: [Data] = []

    func startCapture() throws -> AsyncStream<Data> {
        startCaptureCalls += 1
        onStartCapture?()
        if let startCaptureError { throw startCaptureError }
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        captureContinuation = continuation
        isCapturing = true
        return stream
    }

    func stopCapture() {
        captureContinuation?.finish()
        captureContinuation = nil
        isCapturing = false
    }

    func startPlayback() { isPlaying = true }
    func enqueuePlayback(_ data: Data) { played.append(data) }
    func stopPlayback() { isPlaying = false }
}
