import Foundation
import os

/// Serverless local-LAN coordinator.
/// Discovery uses Bonjour; audio uses direct TCP between peers on the same Wi-Fi network.
@Observable
final class NetworkCoordinator {
    let controlPlane: any ControlPlane
    private let udpAudio: any AudioPlane
    private(set) var activeAudioPlane: (any AudioPlane)?

    var hasAndroidPeers: Bool {
        controlPlane.connectedPeers.contains { $0.platform == .android }
    }

    private(set) var wifiSSID: String?
    private(set) var wifiPassword: String?
    private(set) var wifiHostIP: String?

    let channelCommands: AsyncStream<(BLECommand, PeerInfo)>
    private let channelCommandsCont: AsyncStream<(BLECommand, PeerInfo)>.Continuation
    let channelPeerEvents: AsyncStream<PeerEvent>
    private let channelPeerEventsCont: AsyncStream<PeerEvent>.Continuation

    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    /// Production passes only `displayName`; tests inject fakes (DSCN-23). No behavior change.
    init(
        displayName: String,
        controlPlane: (any ControlPlane)? = nil,
        audioPlane: (any AudioPlane)? = nil
    ) {
        self.controlPlane = controlPlane ?? LocalControlPlane(displayName: displayName)
        self.udpAudio = audioPlane ?? UDPAudioPlane()
        (channelCommands, channelCommandsCont) = AsyncStream.makeStream()
        (channelPeerEvents, channelPeerEventsCont) = AsyncStream.makeStream()
    }

    func start() {
        controlPlane.start()
        listenForCommands()
        listenForPeerChanges()
        Logger.transport.info("NetworkCoordinator started")
    }

    func stop() {
        controlPlane.stop()
        activeAudioPlane?.stop()
        activeAudioPlane = nil
        commandTask?.cancel()
        peerTask?.cancel()
    }

    func selectAudioPlane() -> any AudioPlane {
        Logger.transport.info("Audio plane: local TCP")
        activeAudioPlane = udpAudio
        return udpAudio
    }

    private func listenForCommands() {
        commandTask = Task { [weak self] in
            guard let self else { return }
            for await (command, peer) in self.controlPlane.commands {
                self.channelCommandsCont.yield((command, peer))
            }
        }
    }

    private func listenForPeerChanges() {
        peerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.controlPlane.peerEvents {
                self.channelPeerEventsCont.yield(event)
            }
        }
    }
}
