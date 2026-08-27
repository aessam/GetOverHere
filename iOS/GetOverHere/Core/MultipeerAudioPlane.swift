import MultipeerConnectivity
import Foundation
import Observation
import os

/// MultipeerConnectivity-based audio plane for iOS↔iOS.
/// Used when all peers are iOS (no Android detected).
/// Audio only — discovery/coordination handled by BLE control plane.
@Observable
final class MultipeerAudioPlane: NSObject, AudioPlane {
    private(set) var isActive = false

    private let mcPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    @ObservationIgnored private var onAudioCallback: (@Sendable (Data) -> Void)?

    private static let serviceType = "goh-audio"

    init(displayName: String) {
        let shortID = String(UUID().uuidString.prefix(4))
        self.mcPeerID = MCPeerID(displayName: "\(displayName)_\(shortID)")
        self.session = MCSession(peer: mcPeerID, securityIdentity: nil, encryptionPreference: .none)
        self.advertiser = MCNearbyServiceAdvertiser(peer: mcPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: mcPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    // MARK: - AudioPlane

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isActive = true
        Logger.audio.info("Multipeer audio: broadcasting")
    }

    func sendAudio(_ data: Data) {
        Logger.audio.error("Multipeer raw audio is disabled by encrypted GOH2 v3")
    }

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        self.onAudioCallback = onAudio
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isActive = true
        Logger.audio.info("Multipeer audio: listening")
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        onAudioCallback = nil
        isActive = false
        Logger.audio.info("Multipeer audio: stopped")
    }
}

// MARK: - MCSessionDelegate

extension MultipeerAudioPlane: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            self?.onAudioCallback?(data)
        }
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateStr = switch state { case .connected: "connected"; case .connecting: "connecting"; case .notConnected: "disconnected"; @unknown default: "unknown" }
        Logger.audio.info("Multipeer connection state: \(stateStr)")
    }

    nonisolated func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: (any Error)?) {}
}

// MARK: - Browser + Advertiser

extension MultipeerAudioPlane: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo: [String: String]?) {
        // Auto-invite with tiebreaker
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.mcPeerID.displayName < peerID.displayName {
                browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
            }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        Logger.audio.error("Multipeer browse failed")
    }
}

extension MultipeerAudioPlane: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                 withContext: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            invitationHandler(true, self?.session)
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        Logger.audio.error("Multipeer advertise failed")
    }
}
