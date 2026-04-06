import Foundation
import os

/// Audio-only megaphone service.
/// - Creator of a channel is the ONLY speaker
/// - Everyone else listens
/// - BLE control plane handles discovery + coordination
/// - Audio flows via Multipeer (iOS-only) or UDP (cross-platform via WiFi hotspot)
@Observable
final class ChannelService {

    // MARK: - State

    private(set) var channels: [Channel] = []
    var activeChannelID: String?

    enum ListenState: Equatable {
        case idle
        case listening
        case broadcasting
    }

    private(set) var listenState: ListenState = .idle
    private(set) var listenerCount: Int = 0
    var audioQuality: AudioQuality = .standard

    // MARK: - Dependencies

    private let coordinator: NetworkCoordinator
    private let audioEngine: AudioEngine
    private var captureTask: Task<Void, Never>?
    private var listenTasks: [Task<Void, Never>] = []

    // MARK: - Computed

    var activeChannel: Channel? {
        channels.first { $0.id == activeChannelID }
    }

    var isCreator: Bool {
        guard let ch = activeChannel else { return false }
        return ch.createdBy == coordinator.controlPlane.localPeer.id
    }

    var connectedPeers: [PeerInfo] {
        coordinator.controlPlane.connectedPeers
    }

    var localPeer: PeerInfo {
        coordinator.controlPlane.localPeer
    }

    // MARK: - Init

    init(coordinator: NetworkCoordinator, audioEngine: AudioEngine) {
        self.coordinator = coordinator
        self.audioEngine = audioEngine
    }

    func startListening() {
        listenForChannelCommands()
        listenForPeerEvents()
        startPeriodicBroadcast()
        Logger.channel.info("ChannelService started")
    }

    // MARK: - Channel Management

    func createChannel(name: String) {
        let channel = Channel(
            id: UUID().uuidString,
            name: name,
            createdAt: Date(),
            createdBy: coordinator.controlPlane.localPeer.id
        )
        channels.append(channel)
        activeChannelID = channel.id
        listenState = .broadcasting

        // Announce channel via BLE
        broadcastChannelAnnounce(channel)

        // Select audio plane and start broadcasting
        let plane = coordinator.selectAudioPlane()
        plane.startBroadcasting(channelID: channel.id, quality: audioQuality)

        // Start capturing + sending audio
        startCapturing(plane: plane, channelID: channel.id)

        Logger.channel.info("Created megaphone: \(name) (quality: \(self.audioQuality.label))")
    }

    func joinChannel(_ channel: Channel) {
        stopCurrentActivity()
        activeChannelID = channel.id
        listenState = .listening

        // Select audio plane and start listening
        let plane = coordinator.selectAudioPlane()
        // For TCP audio: set the speaker's IP before connecting
        if let tcpPlane = plane as? UDPAudioPlane {
            tcpPlane.hostIP = channel.audioHostIP
            Logger.channel.info("TCP audio target: \(tcpPlane.hostIP ?? "nil")")
        }
        audioEngine.startPlayback()
        plane.startListening(channelID: channel.id) { [weak self] data in
            Task { @MainActor in
                self?.audioEngine.enqueuePlayback(data)
            }
        }

        Logger.channel.info("Listening to: \(channel.name)")
    }

    func leaveChannel() {
        guard let ch = activeChannel else { return }
        stopCurrentActivity()
        activeChannelID = nil
        listenState = .idle
        Logger.channel.info("Left channel: \(ch.name)")

        if ch.createdBy == coordinator.controlPlane.localPeer.id {
            channels.removeAll { $0.id == ch.id }
            coordinator.controlPlane.broadcast(.channelEnded(channelID: ch.id))
        }
    }

    // MARK: - Private

    private func startCapturing(plane: any AudioPlane, channelID: String) {
        let stream = audioEngine.startCapture()
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await data in stream {
                guard !Task.isCancelled else { break }
                plane.sendAudio(data)
            }
        }
    }

    private func stopCurrentActivity() {
        if listenState == .broadcasting {
            audioEngine.stopCapture()
            captureTask?.cancel()
            captureTask = nil
        } else if listenState == .listening {
            audioEngine.stopPlayback()
        }
        coordinator.activeAudioPlane?.stop()
    }

    private func broadcastChannelAnnounce(_ channel: Channel) {
        guard channel.createdBy == coordinator.controlPlane.localPeer.id else { return }
        let announce = BLECommand.ChannelAnnounce(
            channelID: channel.id,
            channelName: channel.name,
            createdBy: channel.createdBy,
            audioQuality: audioQuality,
            wifiSSID: nil,
            audioHostIP: channel.audioHostIP
        )
        coordinator.controlPlane.broadcast(.channelAnnounce(announce: announce))
    }

    private func broadcastAllChannels() {
        for channel in channels {
            broadcastChannelAnnounce(channel)
        }
    }

    // MARK: - Periodic Broadcast

    private func startPeriodicBroadcast() {
        listenTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.channels.isEmpty else { continue }
                self.broadcastAllChannels()
            }
        })
    }

    // MARK: - Command Listeners

    private func listenForChannelCommands() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (command, _) in self.coordinator.channelCommands {
                switch command {
                case .channelAnnounce(announce: let announce):
                    if let idx = self.channels.firstIndex(where: { $0.id == announce.channelID }) {
                        let previousHostIP = self.channels[idx].audioHostIP
                        self.channels[idx].name = announce.channelName
                        self.channels[idx].audioHostIP = announce.audioHostIP
                        Logger.channel.info("Updated megaphone: \(announce.channelName) (audioHostIP=\(announce.audioHostIP ?? "nil"))")

                        if self.activeChannelID == announce.channelID,
                           self.listenState == .listening,
                           previousHostIP != announce.audioHostIP,
                           let updatedChannel = self.channels[safe: idx] {
                            self.joinChannel(updatedChannel)
                        }
                    } else {
                        let channel = Channel(
                            id: announce.channelID,
                            name: announce.channelName,
                            createdAt: Date(),
                            createdBy: announce.createdBy,
                            audioHostIP: announce.audioHostIP
                        )
                        self.channels.append(channel)
                        Logger.channel.info("Discovered megaphone: \(channel.name) (audioHostIP=\(announce.audioHostIP ?? "nil"))")
                    }
                case .channelEnded(let channelID):
                    self.channels.removeAll { $0.id == channelID }
                    if self.activeChannelID == channelID {
                        self.stopCurrentActivity()
                        self.activeChannelID = nil
                        self.listenState = .idle
                        Logger.channel.info("Channel ended")
                    }

                default:
                    break
                }
            }
        })
    }

    private func listenForPeerEvents() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.coordinator.channelPeerEvents {
                if case .connected = event {
                    self.broadcastAllChannels()
                    self.listenerCount = self.coordinator.controlPlane.connectedPeers.count
                }
                if case .disconnected = event {
                    self.listenerCount = self.coordinator.controlPlane.connectedPeers.count
                }
            }
        })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
