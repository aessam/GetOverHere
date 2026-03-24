import Foundation
import os

@Observable
final class WalkieTalkieService {
    enum FloorState: Equatable {
        case idle
        case requesting
        case broadcasting
        case listening(speakerName: String)
    }

    private(set) var floorState: FloorState = .idle
    private(set) var channels: [Channel] = []
    var currentChannel: Channel?

    private let transport: any TransportProtocol
    private let audioEngine: AudioEngine
    private var captureTask: Task<Void, Never>?
    private var audioListenTask: Task<Void, Never>?
    private var controlListenTask: Task<Void, Never>?

    init(transport: any TransportProtocol, audioEngine: AudioEngine) {
        self.transport = transport
        self.audioEngine = audioEngine
    }

    func startListening() {
        listenForAudio()
        listenForControls()
    }

    // MARK: - Channel Management

    func createChannel(name: String) -> Channel {
        let channel = Channel(name: name, memberIDs: [transport.localPeer.id])
        channels.append(channel)
        currentChannel = channel
        Logger.walkieTalkie.info("Created channel: \(name)")

        let control = TransportMessage.WalkieTalkieControl.joinChannel(
            channelID: channel.id.uuidString,
            channelName: name,
            peerID: transport.localPeer.id,
            peerName: transport.localPeer.displayName
        )
        sendControl(control)
        return channel
    }

    func joinChannel(_ channel: Channel) {
        currentChannel = channel
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index].memberIDs.insert(transport.localPeer.id)
        }

        let control = TransportMessage.WalkieTalkieControl.joinChannel(
            channelID: channel.id.uuidString,
            channelName: channel.name,
            peerID: transport.localPeer.id,
            peerName: transport.localPeer.displayName
        )
        sendControl(control)
        Logger.walkieTalkie.info("Joined channel: \(channel.name)")
    }

    func leaveChannel() {
        guard let channel = currentChannel else { return }
        releaseFloor()

        let control = TransportMessage.WalkieTalkieControl.leaveChannel(
            channelID: channel.id.uuidString,
            peerID: transport.localPeer.id
        )
        sendControl(control)

        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index].memberIDs.remove(transport.localPeer.id)
        }
        currentChannel = nil
        floorState = .idle
        Logger.walkieTalkie.info("Left channel: \(channel.name)")
    }

    // MARK: - Push to Talk

    func pushToTalk() {
        guard floorState == .idle, let channel = currentChannel else { return }

        floorState = .broadcasting

        let stream = audioEngine.startCapture()
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await data in stream {
                do {
                    try self.transport.sendAudioData(data, to: [])
                } catch {
                    Logger.walkieTalkie.error("Audio send failed: \(error.localizedDescription)")
                }
            }
        }

        let control = TransportMessage.WalkieTalkieControl.requestFloor(
            channelID: channel.id.uuidString,
            peerID: transport.localPeer.id,
            peerName: transport.localPeer.displayName
        )
        sendControl(control)
        Logger.walkieTalkie.info("Broadcasting on channel: \(channel.name)")
    }

    func releaseFloor() {
        guard floorState == .broadcasting, let channel = currentChannel else { return }

        audioEngine.stopCapture()
        captureTask?.cancel()
        captureTask = nil
        floorState = .idle

        let control = TransportMessage.WalkieTalkieControl.releaseFloor(
            channelID: channel.id.uuidString,
            peerID: transport.localPeer.id
        )
        sendControl(control)
        Logger.walkieTalkie.info("Released floor on channel: \(channel.name)")
    }

    // MARK: - Private

    private func sendControl(_ control: TransportMessage.WalkieTalkieControl) {
        do {
            try transport.send(.walkieTalkieControl(control), to: [])
        } catch {
            Logger.walkieTalkie.error("Failed to send control: \(error.localizedDescription)")
        }
    }

    private func listenForAudio() {
        audioListenTask?.cancel()
        audioListenTask = Task { [weak self] in
            guard let self else { return }
            for await (data, _) in self.transport.audioData {
                if case .listening = self.floorState {
                    self.audioEngine.enqueuePlayback(data)
                }
            }
        }
    }

    private func listenForControls() {
        controlListenTask?.cancel()
        controlListenTask = Task { [weak self] in
            guard let self else { return }
            for await (control, peer) in self.transport.controlMessages {
                self.handleControl(control, from: peer)
            }
        }
    }

    private func handleControl(_ control: TransportMessage.WalkieTalkieControl, from peer: PeerInfo) {
        switch control {
        case .requestFloor(let channelID, _, let peerName):
            guard currentChannel?.id.uuidString == channelID else { return }
            if floorState == .idle {
                floorState = .listening(speakerName: peerName)
                audioEngine.startPlayback()
                Logger.walkieTalkie.info("\(peerName) is speaking")
            }

        case .releaseFloor(let channelID, _):
            guard currentChannel?.id.uuidString == channelID else { return }
            if case .listening = floorState {
                audioEngine.stopPlayback()
                floorState = .idle
                Logger.walkieTalkie.info("Floor released")
            }

        case .joinChannel(let channelID, let channelName, let peerID, let peerName):
            if let index = channels.firstIndex(where: { $0.id.uuidString == channelID }) {
                channels[index].memberIDs.insert(peerID)
                Logger.walkieTalkie.info("\(peerName) joined existing channel")
            } else {
                let channel = Channel(
                    id: UUID(uuidString: channelID) ?? UUID(),
                    name: channelName,
                    memberIDs: [peerID, transport.localPeer.id]
                )
                channels.append(channel)
                Logger.walkieTalkie.info("Discovered channel '\(channelName)' from \(peerName)")
            }

        case .leaveChannel(let channelID, let peerID):
            if let index = channels.firstIndex(where: { $0.id.uuidString == channelID }) {
                channels[index].memberIDs.remove(peerID)
            }

        case .grantFloor, .denyFloor:
            break
        }
    }
}
