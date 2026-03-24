import MultipeerConnectivity
import os

@Observable
final class MultipeerTransport: NSObject, TransportProtocol {
    let localPeer: PeerInfo
    private(set) var discoveredPeers: [PeerInfo] = []
    private(set) var connectedPeers: [PeerInfo] = []

    // MARK: - Async Streams

    let textMessages: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>
    let controlMessages: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>
    let channelAnnouncements: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>
    let fileHeaders: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>
    let fileChunks: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>
    let audioData: AsyncStream<(Data, PeerInfo)>
    let fileTransfers: AsyncStream<FileTransferEvent>
    let peerEvents: AsyncStream<PeerEvent>

    // MARK: - Private

    private let mcPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var peerIDMap: [MCPeerID: PeerInfo] = [:]

    private let textContinuation: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>.Continuation
    private let controlContinuation: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>.Continuation
    private let announceContinuation: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>.Continuation
    private let fileHeaderContinuation: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>.Continuation
    private let fileChunkContinuation: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>.Continuation
    private let audioContinuation: AsyncStream<(Data, PeerInfo)>.Continuation
    private let fileContinuation: AsyncStream<FileTransferEvent>.Continuation
    private let peerContinuation: AsyncStream<PeerEvent>.Continuation

    private static let serviceType = "goh-chat"

    // MARK: - Init

    init(displayName: String) {
        // Unique MCPeerID (tiebreaker needs unique names), but localPeer keeps clean device name
        let shortID = String(UUID().uuidString.prefix(4))
        self.mcPeerID = MCPeerID(displayName: "\(displayName)_\(shortID)")
        self.localPeer = PeerInfo(id: "\(displayName)_\(shortID)", displayName: displayName)
        self.session = MCSession(peer: mcPeerID, securityIdentity: nil, encryptionPreference: .none)
        // Pass real device name in discoveryInfo so peers show "iPhone" not "iPhone_A3F2"
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: mcPeerID,
            discoveryInfo: ["name": displayName],
            serviceType: Self.serviceType
        )
        self.browser = MCNearbyServiceBrowser(peer: mcPeerID, serviceType: Self.serviceType)

        (self.textMessages, self.textContinuation) = AsyncStream.makeStream()
        (self.controlMessages, self.controlContinuation) = AsyncStream.makeStream()
        (self.channelAnnouncements, self.announceContinuation) = AsyncStream.makeStream()
        (self.fileHeaders, self.fileHeaderContinuation) = AsyncStream.makeStream()
        (self.fileChunks, self.fileChunkContinuation) = AsyncStream.makeStream()
        (self.audioData, self.audioContinuation) = AsyncStream.makeStream()
        (self.fileTransfers, self.fileContinuation) = AsyncStream.makeStream()
        (self.peerEvents, self.peerContinuation) = AsyncStream.makeStream()

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    deinit {
        stop()
        textContinuation.finish()
        controlContinuation.finish()
        announceContinuation.finish()
        fileHeaderContinuation.finish()
        fileChunkContinuation.finish()
        audioContinuation.finish()
        fileContinuation.finish()
        peerContinuation.finish()
    }

    // MARK: - Transport Actions

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        Logger.transport.info("Started advertising and browsing")
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        discoveredPeers.removeAll()
        connectedPeers.removeAll()
        peerIDMap.removeAll()
        Logger.transport.info("Stopped transport")
    }

    func invitePeer(_ peer: PeerInfo) {
        guard let mcPeer = mcPeerID(for: peer) else {
            Logger.transport.error("Cannot invite unknown peer: \(peer.displayName)")
            return
        }
        browser.invitePeer(mcPeer, to: session, withContext: nil, timeout: 30)
        Logger.transport.info("Invited peer: \(peer.displayName)")
    }

    func send(_ message: TransportMessage, to peers: [PeerInfo]) throws {
        let encoded = try JSONEncoder().encode(message)
        var data = Data([DataTag.message.rawValue])
        data.append(encoded)
        let targets = resolveTargets(peers)
        guard !targets.isEmpty else { return }
        try session.send(data, toPeers: targets, with: .reliable)
    }

    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws {
        var tagged = Data([DataTag.audio.rawValue])
        tagged.append(data)
        let targets = resolveTargets(peers)
        guard !targets.isEmpty else {
            Logger.transport.debug("sendAudioData: no targets, dropping \(data.count) bytes")
            return
        }
        try session.send(tagged, toPeers: targets, with: .unreliable)
    }

    @discardableResult
    func sendFile(at url: URL, named name: String, to peer: PeerInfo) -> Progress {
        guard let mcPeer = mcPeerID(for: peer) else {
            Logger.transport.error("Cannot send file to unknown peer: \(peer.displayName)")
            return Progress(totalUnitCount: 0)
        }
        guard let progress = session.sendResource(at: url, withName: name, toPeer: mcPeer, withCompletionHandler: { error in
            if let error {
                Logger.transport.error("File send failed: \(error.localizedDescription)")
            } else {
                Logger.transport.info("File sent: \(name)")
            }
        }) else {
            return Progress(totalUnitCount: 0)
        }
        return progress
    }

    // MARK: - Helpers

    private func mcPeerID(for peer: PeerInfo) -> MCPeerID? {
        peerIDMap.first(where: { $0.value.id == peer.id })?.key
    }

    private func resolveTargets(_ peers: [PeerInfo]) -> [MCPeerID] {
        if peers.isEmpty {
            return session.connectedPeers
        }
        return peers.compactMap { mcPeerID(for: $0) }
    }

    private func peerInfo(for mcPeer: MCPeerID) -> PeerInfo {
        if let existing = peerIDMap[mcPeer] {
            return existing
        }
        // Strip the _XXXX unique suffix to get clean device name
        let fullID = mcPeer.displayName
        let cleanName: String
        if let lastUnderscore = fullID.lastIndex(of: "_"),
           fullID.distance(from: lastUnderscore, to: fullID.endIndex) == 5 {
            cleanName = String(fullID[fullID.startIndex..<lastUnderscore])
        } else {
            cleanName = fullID
        }
        let info = PeerInfo(id: fullID, displayName: cleanName)
        peerIDMap[mcPeer] = info
        return info
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count > 1, let tag = DataTag(rawValue: data[0]) else {
            Logger.transport.warning("Received malformed data (\(data.count) bytes) from \(peerID.displayName)")
            return
        }
        let payload = data.subdata(in: 1..<data.count)
        if tag == .audio {
            Logger.transport.debug("Audio packet: \(payload.count) bytes from \(peerID.displayName)")
        } else {
            Logger.transport.info("Message packet: \(payload.count) bytes from \(peerID.displayName)")
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peerInfo(for: peerID)

            switch tag {
            case .message:
                guard let message = try? JSONDecoder().decode(TransportMessage.self, from: payload) else {
                    Logger.transport.error("Failed to decode message from \(peer.displayName)")
                    return
                }
                switch message {
                case .text(let textPayload):
                    self.textContinuation.yield((textPayload, peer))
                case .walkieTalkieControl(let control):
                    self.controlContinuation.yield((control, peer))
                case .channelAnnounce(let announce):
                    self.announceContinuation.yield((announce, peer))
                case .fileHeader(let header):
                    self.fileHeaderContinuation.yield((header, peer))
                case .fileChunk(let chunk):
                    self.fileChunkContinuation.yield((chunk, peer))
                }
            case .audio:
                self.audioContinuation.yield((payload, peer))
            }
        }
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peerInfo(for: peerID)

            switch state {
            case .connected:
                if !self.connectedPeers.contains(peer) {
                    self.connectedPeers.append(peer)
                }
                self.discoveredPeers.removeAll { $0.id == peer.id }
                self.peerContinuation.yield(.connected(peer))
                Logger.transport.info("Connected to \(peer.displayName)")
            case .notConnected:
                self.connectedPeers.removeAll { $0.id == peer.id }
                self.peerContinuation.yield(.disconnected(peer))
                Logger.transport.info("Disconnected from \(peer.displayName)")
            case .connecting:
                self.peerContinuation.yield(.connecting(peer))
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        // Not used — audio is sent as discrete packets via send()
    }

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peerInfo(for: peerID)
            self.fileContinuation.yield(.receiving(fileName: resourceName, from: peer))
            Logger.transport.info("Receiving file: \(resourceName) from \(peer.displayName)")
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peerInfo(for: peerID)

            if let error {
                self.fileContinuation.yield(.failed(
                    fileName: resourceName,
                    from: peer,
                    errorDescription: error.localizedDescription
                ))
            } else if let localURL {
                // Move to permanent location
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let dest = docs.appendingPathComponent("Received").appendingPathComponent(resourceName)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: localURL, to: dest)
                self.fileContinuation.yield(.received(fileName: resourceName, from: peer, localURL: dest))
                Logger.transport.info("Received file: \(resourceName) from \(peer.displayName)")
            }
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Use real device name from discoveryInfo, not the unique MCPeerID
            let realName = info?["name"] ?? peerID.displayName
            let peer = PeerInfo(id: peerID.displayName, displayName: realName)
            self.peerIDMap[peerID] = peer
            if !self.discoveredPeers.contains(peer) && !self.connectedPeers.contains(peer) {
                self.discoveredPeers.append(peer)
            }
            self.peerContinuation.yield(.discovered(peer))
            Logger.transport.info("Discovered peer: \(realName)")

            // Auto-connect with tiebreaker: only the device with the
            // lexicographically smaller displayName invites.
            // This prevents both sides inviting simultaneously which kills MCSession.
            if self.mcPeerID.displayName < peerID.displayName {
                self.browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
                Logger.transport.info("Auto-inviting peer: \(peer.displayName) (we are smaller)")
            } else {
                Logger.transport.info("Waiting for invite from: \(peer.displayName) (they are smaller)")
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peerInfo(for: peerID)
            self.discoveredPeers.removeAll { $0.id == peer.id }
            self.peerContinuation.yield(.lost(peer))
            Logger.transport.info("Lost peer: \(peer.displayName)")
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        Logger.transport.error("Browser failed: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Auto-accept invitations for the prototype
        Task { @MainActor [weak self] in
            guard let self else { return }
            invitationHandler(true, self.session)
            Logger.transport.info("Accepted invitation from \(peerID.displayName)")
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        Logger.transport.error("Advertiser failed: \(error.localizedDescription)")
    }
}
