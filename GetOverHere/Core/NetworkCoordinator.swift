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

    /// WiFi hotspot SSID (set when Android shares credentials)
    private(set) var wifiSSID: String?
    private(set) var wifiPassword: String?

    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    init(displayName: String) {
        self.controlPlane = BLEControlPlane(displayName: displayName)
        self.leaderElection = LeaderElection(controlPlane: controlPlane)
        self.multipeerAudio = MultipeerAudioPlane(displayName: displayName)
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
            // Cross-platform: use UDP over WiFi hotspot
            Logger.transport.info("Audio plane: UDP (cross-platform WiFi)")
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
                switch command {
                case .wifiCredentials(let ssid, let password):
                    self.wifiSSID = ssid
                    self.wifiPassword = password
                    Logger.transport.info("WiFi credentials received: \(ssid)")
                    // Auto-join the hotspot
                    self.wifiJoiner.join(ssid: ssid, password: password)

                case .becomeWiFiHost:
                    // Android handles this — iOS can't create hotspot
                    Logger.transport.info("Received becomeWiFiHost (iOS can't fulfill, ignoring)")

                default:
                    break // Channel commands handled by ChannelService
                }
            }
        }
    }

    private func listenForPeerChanges() {
        peerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.controlPlane.peerEvents {
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
