import Foundation
import os

/// Orchestrates the three-tier network: BLE control + leader election + audio plane.
/// Decides which audio plane to use (Multipeer vs WiFi+UDP) based on connected peers.
@Observable
final class NetworkCoordinator {
    let controlPlane: BLEControlPlane
    let leaderElection: LeaderElection
    let wifiJoiner = WiFiHotspotJoiner()

    private let multipeerAudio: MultipeerAudioPlane
    private let udpAudio = UDPAudioPlane()

    /// The currently active audio plane
    private(set) var activeAudioPlane: (any AudioPlane)?

    /// Whether an Android device is connected
    var hasAndroidPeers: Bool {
        controlPlane.connectedPeers.contains { $0.platform == .android }
    }

    /// WiFi hotspot info (set when Android shares credentials)
    private(set) var wifiSSID: String?
    private(set) var wifiPassword: String?
    private(set) var wifiHostIP: String?

    /// Re-published streams for ChannelService (AsyncStream is single-consumer)
    let channelCommands: AsyncStream<(BLECommand, PeerInfo)>
    private let channelCommandsCont: AsyncStream<(BLECommand, PeerInfo)>.Continuation
    let channelPeerEvents: AsyncStream<PeerEvent>
    private let channelPeerEventsCont: AsyncStream<PeerEvent>.Continuation

    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    init(displayName: String) {
        self.controlPlane = BLEControlPlane(displayName: displayName)
        self.leaderElection = LeaderElection(controlPlane: controlPlane)
        self.multipeerAudio = MultipeerAudioPlane(displayName: displayName)
        (channelCommands, channelCommandsCont) = AsyncStream.makeStream()
        (channelPeerEvents, channelPeerEventsCont) = AsyncStream.makeStream()
    }

    func start() {
        controlPlane.start()
        leaderElection.start()
        listenForCommands()
        listenForPeerChanges()
        Logger.transport.info("NetworkCoordinator started")
    }

    func stop() {
        controlPlane.stop()
        leaderElection.stop()
        activeAudioPlane?.stop()
        activeAudioPlane = nil
        commandTask?.cancel()
        peerTask?.cancel()
        wifiJoiner.disconnect()
    }

    // MARK: - Audio Plane Selection

    /// Choose the right audio plane based on current peers.
    /// Called when peers change or when starting a broadcast.
    func selectAudioPlane() -> any AudioPlane {
        if hasAndroidPeers && wifiSSID != nil {
            // Cross-platform: use TCP over WiFi hotspot
            udpAudio.hostIP = wifiHostIP
            Logger.transport.info("Audio plane: TCP (cross-platform WiFi, hostIP=\(self.wifiHostIP ?? "none"))")
            activeAudioPlane = udpAudio
            return udpAudio
        } else {
            // iOS-only: use MultipeerConnectivity
            Logger.transport.info("Audio plane: Multipeer (iOS-only)")
            activeAudioPlane = multipeerAudio
            return multipeerAudio
        }
    }

    // MARK: - WiFi Hotspot Flow

    /// Called when we need cross-platform audio and Android is present.
    /// Sends "become WiFi host" command to the Android leader.
    func requestWiFiHotspot() {
        guard hasAndroidPeers else { return }
        // Find Android peer
        if let androidPeer = controlPlane.connectedPeers.first(where: { $0.platform == .android }) {
            controlPlane.send(.becomeWiFiHost, to: androidPeer)
            Logger.transport.info("Requested WiFi hotspot from \(androidPeer.displayName)")
        }
    }

    // MARK: - Command Handling

    private func listenForCommands() {
        commandTask = Task { [weak self] in
            guard let self else { return }
            for await (command, peer) in self.controlPlane.commands {
                // Forward ALL commands to ChannelService
                self.channelCommandsCont.yield((command, peer))

                // Handle network-level commands here
                switch command {
                case .wifiCredentials(let ssid, let password, let hostIP):
                    self.wifiSSID = ssid
                    self.wifiPassword = password
                    self.wifiHostIP = hostIP
                    Logger.transport.info("WiFi credentials received: \(ssid), hostIP: \(hostIP ?? "none")")
                    self.controlPlane.updatePeerPlatform(peerID: peer.id, platform: .android)
                    self.wifiJoiner.join(ssid: ssid, password: password)

                case .becomeWiFiHost:
                    Logger.transport.info("Received becomeWiFiHost (iOS can't fulfill)")

                default:
                    break
                }
            }
        }
    }

    private func listenForPeerChanges() {
        peerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.controlPlane.peerEvents {
                // Forward to ChannelService
                self.channelPeerEventsCont.yield(event)

                if case .connected(let peer) = event, peer.platform == .android {
                    // Android just appeared — request WiFi hotspot
                    Logger.transport.info("Android peer detected: \(peer.displayName)")
                    // Give RAFT a moment to elect Android as leader, then request hotspot
                    try? await Task.sleep(for: .seconds(5))
                    self.requestWiFiHotspot()
                }
            }
        }
    }
}
