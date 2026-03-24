import Foundation
import os

/// Audio-only megaphone service.
/// - Creator of a channel is the ONLY speaker
/// - Everyone else listens
/// - On boot, broadcasts "any channels?" to discover existing megaphones
/// - On peer connect, shares all known channels
@Observable
final class ChannelService {

    // MARK: - State

    private(set) var channels: [Channel] = []
    var activeChannelID: String?

    enum ListenState: Equatable {
        case idle           // not in any channel
        case listening      // in a channel, hearing audio
        case broadcasting   // I created this channel, I'm the megaphone
    }

    private(set) var listenState: ListenState = .idle
    private(set) var listenerCount: Int = 0

    // MARK: - Dependencies

    private let transport: any TransportProtocol
    private let audioEngine: AudioEngine
    private var captureTask: Task<Void, Never>?
    private var listenTasks: [Task<Void, Never>] = []

    // MARK: - Computed

    var activeChannel: Channel? {
        channels.first { $0.id == activeChannelID }
    }

    var isCreator: Bool {
        guard let ch = activeChannel else { return false }
        return ch.createdBy == transport.localPeer.id
    }

    // MARK: - Init

    init(transport: any TransportProtocol, audioEngine: AudioEngine) {
        self.transport = transport
        self.audioEngine = audioEngine
    }

    func startListening() {
        listenForAudio()
        listenForChannelAnnouncements()
        listenForPeerEvents()
        listenForControl()
        Logger.channel.info("ChannelService started")
    }

    // MARK: - Channel Management

    /// Create a megaphone channel — you become the speaker.
    /// Auto-enables BLE so Android devices can discover and listen.
    func createChannel(name: String) {
        let channel = Channel(
            id: UUID().uuidString,
            name: name,
            createdAt: Date(),
            createdBy: transport.localPeer.id
        )
        channels.append(channel)
        activeChannelID = channel.id
        listenState = .broadcasting

        broadcastChannelAnnounce(channel)
        startBroadcasting()
        Logger.channel.info("Created megaphone: \(name)")
    }

    /// Join a channel as a listener.
    func joinChannel(_ channel: Channel) {
        // Stop current activity
        stopCurrentActivity()

        activeChannelID = channel.id
        listenState = .listening
        audioEngine.startPlayback()
        Logger.channel.info("Listening to: \(channel.name)")
    }

    /// Leave the current channel.
    func leaveChannel() {
        guard let ch = activeChannel else { return }
        stopCurrentActivity()
        activeChannelID = nil
        listenState = .idle
        Logger.channel.info("Left channel: \(ch.name)")

        // If I was the creator, broadcast that channel is dead
        if ch.createdBy == transport.localPeer.id {
            channels.removeAll { $0.id == ch.id }
            // Notify peers the channel ended
            let control = TransportMessage.WalkieTalkieControl.releaseFloor(
                channelID: ch.id,
                peerID: transport.localPeer.id
            )
            try? transport.send(.walkieTalkieControl(control), to: [])
        }
    }

    // MARK: - Broadcasting (creator only)

    private func startBroadcasting() {
        let stream = audioEngine.startCapture()
        let channelID = activeChannelID ?? ""

        // Notify listeners I'm live
        let control = TransportMessage.WalkieTalkieControl.requestFloor(
            channelID: channelID,
            peerID: transport.localPeer.id,
            peerName: transport.localPeer.displayName
        )
        try? transport.send(.walkieTalkieControl(control), to: [])

        captureTask = Task { [weak self] in
            guard let self else { return }
            for await data in stream {
                guard !Task.isCancelled else { break }
                // Prepend channelID (36 bytes UTF-8) to audio so listeners can filter
                var tagged = Data(channelID.utf8)
                tagged.append(data)
                try? self.transport.sendAudioData(tagged, to: [])
            }
        }
        Logger.channel.info("Broadcasting started")
    }

    private func stopCurrentActivity() {
        if listenState == .broadcasting {
            audioEngine.stopCapture()
            captureTask?.cancel()
            captureTask = nil
        } else if listenState == .listening {
            audioEngine.stopPlayback()
        }
    }

    // MARK: - Channel Announce

    private func broadcastChannelAnnounce(_ channel: Channel) {
        let announce = TransportMessage.ChannelAnnounce(
            channelID: channel.id,
            channelName: channel.name,
            createdAt: channel.createdAt,
            createdBy: channel.createdBy
        )
        do {
            try transport.send(.channelAnnounce(announce), to: [])
        } catch {
            Logger.channel.error("Failed to broadcast announce: \(error.localizedDescription)")
        }
    }

    private func broadcastAllChannels() {
        for channel in channels {
            broadcastChannelAnnounce(channel)
        }
    }

    // MARK: - Listeners

    private func listenForAudio() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (data, _) in self.transport.audioData {
                guard self.listenState == .listening,
                      let channelID = self.activeChannelID else { continue }

                // First 36 bytes = channelID, rest = audio
                guard data.count > 36 else { continue }
                let packetChannelID = String(data: data.prefix(36), encoding: .utf8) ?? ""
                guard packetChannelID == channelID else { continue }

                let audioData = data.subdata(in: 36..<data.count)
                self.audioEngine.enqueuePlayback(audioData)
            }
        })
    }

    private func listenForChannelAnnouncements() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (announce, _) in self.transport.channelAnnouncements {
                guard !self.channels.contains(where: { $0.id == announce.channelID }) else { continue }
                let channel = Channel(
                    id: announce.channelID,
                    name: announce.channelName,
                    createdAt: announce.createdAt,
                    createdBy: announce.createdBy
                )
                self.channels.append(channel)
                Logger.channel.info("Discovered megaphone: \(channel.name)")
            }
        })
    }

    private func listenForControl() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (control, _) in self.transport.controlMessages {
                switch control {
                case .releaseFloor(let channelID, _):
                    // Channel creator left — channel is dead
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
            for await event in self.transport.peerEvents {
                if case .connected = event {
                    // New peer joined — tell them about all channels
                    self.broadcastAllChannels()
                    self.listenerCount = self.transport.connectedPeers.count
                }
                if case .disconnected = event {
                    self.listenerCount = self.transport.connectedPeers.count
                }
            }
        })
    }
}
