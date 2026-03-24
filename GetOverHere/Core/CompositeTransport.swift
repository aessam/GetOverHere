import Foundation
import os

/// Wraps MultipeerTransport (iOS-iOS) and optionally BLETransport (iOS-Android bridge).
/// When bridge mode is enabled, relays messages between the two meshes.
@Observable
final class CompositeTransport: TransportProtocol {
    let localPeer: PeerInfo
    private(set) var discoveredPeers: [PeerInfo] = []
    private(set) var connectedPeers: [PeerInfo] = []

    var isBridgeEnabled = false
    var debugLog: [String] = []

    private func log(_ msg: String) {
        Logger.transport.info("\(msg)")
        Task { @MainActor [weak self] in
            self?.debugLog.append(msg)
            if (self?.debugLog.count ?? 0) > 20 { self?.debugLog.removeFirst() }
        }
    }

    let textMessages: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>
    let controlMessages: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>
    let channelAnnouncements: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>
    let fileHeaders: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>
    let fileChunks: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>
    let audioData: AsyncStream<(Data, PeerInfo)>
    let fileTransfers: AsyncStream<FileTransferEvent>
    let peerEvents: AsyncStream<PeerEvent>

    private let textCont: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>.Continuation
    private let controlCont: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>.Continuation
    private let announceCont: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>.Continuation
    private let fileHeaderCont: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>.Continuation
    private let fileChunkCont: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>.Continuation
    private let audioCont: AsyncStream<(Data, PeerInfo)>.Continuation
    private let fileCont: AsyncStream<FileTransferEvent>.Continuation
    private let peerCont: AsyncStream<PeerEvent>.Continuation

    private let multipeer: MultipeerTransport
    private var ble: BLETransport?

    // Which transport owns each peer
    private var peerOrigin: [String: Origin] = [:]
    private enum Origin { case multipeer, ble }

    // Dedup relay sets (per spec §4.2)
    private var seenTextIDs: Set<String> = []
    private var seenFileChunks: Set<String> = []    // "{transferID}:{index}"
    private var seenChannels: Set<String> = []       // channelID

    // Forwarding tasks
    private var forwardTasks: [Task<Void, Never>] = []

    init(displayName: String) {
        let peer = PeerInfo(displayName: displayName)
        self.localPeer = peer
        self.multipeer = MultipeerTransport(displayName: displayName)

        (textMessages, textCont) = AsyncStream.makeStream()
        (controlMessages, controlCont) = AsyncStream.makeStream()
        (channelAnnouncements, announceCont) = AsyncStream.makeStream()
        (fileHeaders, fileHeaderCont) = AsyncStream.makeStream()
        (fileChunks, fileChunkCont) = AsyncStream.makeStream()
        (audioData, audioCont) = AsyncStream.makeStream()
        (fileTransfers, fileCont) = AsyncStream.makeStream()
        (peerEvents, peerCont) = AsyncStream.makeStream()
    }

    // MARK: - Lifecycle

    func start() {
        multipeer.start()
        startMultipeerForwarding()
        log("STARTED: multipeer active, bridge=\(isBridgeEnabled)")
    }

    func stop() {
        multipeer.stop()
        ble?.stop()
        ble = nil
        forwardTasks.forEach { $0.cancel() }
        forwardTasks.removeAll()
        discoveredPeers.removeAll()
        connectedPeers.removeAll()
        peerOrigin.removeAll()
        seenTextIDs.removeAll()
        seenFileChunks.removeAll()
        seenChannels.removeAll()
    }

    func enableBridge() {
        guard ble == nil else { return }
        isBridgeEnabled = true
        let bleTransport = BLETransport(displayName: localPeer.displayName)
        self.ble = bleTransport
        bleTransport.start()
        startBLEForwarding(bleTransport)
        Logger.transport.info("Bridge mode ENABLED — Android devices can now connect")
    }

    func disableBridge() {
        isBridgeEnabled = false
        ble?.stop()
        ble = nil
        // Remove BLE peers
        let blePeerIDs = peerOrigin.filter { $0.value == .ble }.map(\.key)
        discoveredPeers.removeAll { blePeerIDs.contains($0.id) }
        connectedPeers.removeAll { blePeerIDs.contains($0.id) }
        blePeerIDs.forEach { peerOrigin.removeValue(forKey: $0) }
        Logger.transport.info("Bridge mode DISABLED")
    }

    // MARK: - TransportProtocol

    func invitePeer(_ peer: PeerInfo) {
        switch peerOrigin[peer.id] {
        case .ble: ble?.invitePeer(peer)
        default: multipeer.invitePeer(peer)
        }
    }

    func send(_ message: TransportMessage, to peers: [PeerInfo]) throws {
        if peers.isEmpty {
            try multipeer.send(message, to: [])
            try? ble?.send(message, to: [])
        } else {
            let mp = peers.filter { peerOrigin[$0.id] != .ble }
            let bl = peers.filter { peerOrigin[$0.id] == .ble }
            if !mp.isEmpty { try multipeer.send(message, to: mp) }
            if !bl.isEmpty { try ble?.send(message, to: bl) }
        }
    }

    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws {
        if peers.isEmpty {
            try multipeer.sendAudioData(data, to: [])
            try? ble?.sendAudioData(data, to: [])
        } else {
            let mp = peers.filter { peerOrigin[$0.id] != .ble }
            let bl = peers.filter { peerOrigin[$0.id] == .ble }
            if !mp.isEmpty { try multipeer.sendAudioData(data, to: mp) }
            if !bl.isEmpty { try ble?.sendAudioData(data, to: bl) }
        }
    }

    @discardableResult
    func sendFile(at url: URL, named name: String, to peer: PeerInfo) -> Progress {
        switch peerOrigin[peer.id] {
        case .ble: return ble?.sendFile(at: url, named: name, to: peer) ?? Progress()
        default: return multipeer.sendFile(at: url, named: name, to: peer)
        }
    }

    // MARK: - Multipeer Forwarding

    private func startMultipeerForwarding() {
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (payload, peer) in self.multipeer.textMessages {
                self.textCont.yield((payload, peer))
                if self.isBridgeEnabled, self.seenTextIDs.insert(payload.id).inserted {
                    try? self.ble?.send(.text(payload), to: [])
                }
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (control, peer) in self.multipeer.controlMessages {
                self.controlCont.yield((control, peer))
                if self.isBridgeEnabled {
                    try? self.ble?.send(.walkieTalkieControl(control), to: [])
                }
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (announce, peer) in self.multipeer.channelAnnouncements {
                self.announceCont.yield((announce, peer))
                if self.isBridgeEnabled, self.seenChannels.insert(announce.channelID).inserted {
                    try? self.ble?.send(.channelAnnounce(announce), to: [])
                }
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (header, peer) in self.multipeer.fileHeaders {
                self.fileHeaderCont.yield((header, peer))
                if self.isBridgeEnabled {
                    try? self.ble?.send(.fileHeader(header), to: [])
                }
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (chunk, peer) in self.multipeer.fileChunks {
                self.fileChunkCont.yield((chunk, peer))
                let key = "\(chunk.transferID):\(chunk.index)"
                if self.isBridgeEnabled, self.seenFileChunks.insert(key).inserted {
                    try? self.ble?.send(.fileChunk(chunk), to: [])
                }
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (data, peer) in self.multipeer.audioData {
                self.audioCont.yield((data, peer))
                if self.isBridgeEnabled {
                    try? self.ble?.sendAudioData(data, to: [])
                }
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.multipeer.fileTransfers {
                self.fileCont.yield(event)
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.multipeer.peerEvents {
                self.handlePeerEvent(event, origin: .multipeer)
            }
        })
    }

    // MARK: - BLE Forwarding (started when bridge enabled)

    private func startBLEForwarding(_ bleTransport: BLETransport) {
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (payload, peer) in bleTransport.textMessages {
                guard self.seenTextIDs.insert(payload.id).inserted else { continue }
                self.textCont.yield((payload, peer))
                try? self.multipeer.send(.text(payload), to: [])
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (control, peer) in bleTransport.controlMessages {
                self.controlCont.yield((control, peer))
                try? self.multipeer.send(.walkieTalkieControl(control), to: [])
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (announce, peer) in bleTransport.channelAnnouncements {
                guard self.seenChannels.insert(announce.channelID).inserted else { continue }
                self.announceCont.yield((announce, peer))
                try? self.multipeer.send(.channelAnnounce(announce), to: [])
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (header, peer) in bleTransport.fileHeaders {
                self.fileHeaderCont.yield((header, peer))
                try? self.multipeer.send(.fileHeader(header), to: [])
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (chunk, peer) in bleTransport.fileChunks {
                let key = "\(chunk.transferID):\(chunk.index)"
                guard self.seenFileChunks.insert(key).inserted else { continue }
                self.fileChunkCont.yield((chunk, peer))
                try? self.multipeer.send(.fileChunk(chunk), to: [])
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (data, peer) in bleTransport.audioData {
                self.audioCont.yield((data, peer))
                try? self.multipeer.sendAudioData(data, to: [])
            }
        })
        forwardTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in bleTransport.peerEvents {
                self.handlePeerEvent(event, origin: .ble)
            }
        })
    }

    // MARK: - Peer List Management

    private func handlePeerEvent(_ event: PeerEvent, origin: Origin) {
        switch event {
        case .discovered(var peer):
            peer = deduplicateName(peer)
            peerOrigin[peer.id] = origin
            if !discoveredPeers.contains(peer) && !connectedPeers.contains(peer) {
                discoveredPeers.append(peer)
            }
            log("DISCOVERED: \(peer.displayName) via \(origin)")
            peerCont.yield(.discovered(peer))
        case .connected(var peer):
            peer = deduplicateName(peer)
            peerOrigin[peer.id] = origin
            if !connectedPeers.contains(peer) { connectedPeers.append(peer) }
            discoveredPeers.removeAll { $0.id == peer.id }
            log("CONNECTED: \(peer.displayName) via \(origin)")
            peerCont.yield(.connected(peer))
        case .disconnected(let peer):
            connectedPeers.removeAll { $0.id == peer.id }
            peerOrigin.removeValue(forKey: peer.id)
            peerCont.yield(event)
        case .lost(let peer):
            discoveredPeers.removeAll { $0.id == peer.id }
            peerOrigin.removeValue(forKey: peer.id)
            peerCont.yield(event)
        case .connecting:
            peerCont.yield(event)
        }
    }

    /// Append short ID suffix when multiple peers share the same display name.
    private func deduplicateName(_ peer: PeerInfo) -> PeerInfo {
        let allPeers = connectedPeers + discoveredPeers
        let hasDuplicate = allPeers.contains { $0.displayName == peer.displayName && $0.id != peer.id }
        if hasDuplicate || allPeers.contains(where: { $0.displayName.hasPrefix(peer.displayName + " (") }) {
            let shortID = String(peer.id.suffix(4))
            var updated = peer
            if !peer.displayName.hasSuffix(")") { // don't re-suffix
                updated.displayName = "\(peer.displayName) (\(shortID))"
            }
            return updated
        }
        return peer
    }
}
