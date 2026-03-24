import CoreBluetooth
import Foundation
import os

@Observable
final class BLETransport: NSObject, TransportProtocol {
    let localPeer: PeerInfo
    private(set) var discoveredPeers: [PeerInfo] = []
    private(set) var connectedPeers: [PeerInfo] = []

    let textMessages: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>
    let controlMessages: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>
    let channelAnnouncements: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>
    let fileHeaders: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>
    let fileChunks: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>
    let audioData: AsyncStream<(Data, PeerInfo)>
    let fileTransfers: AsyncStream<FileTransferEvent>
    let peerEvents: AsyncStream<PeerEvent>

    private let textContinuation: AsyncStream<(TransportMessage.TextPayload, PeerInfo)>.Continuation
    private let controlContinuation: AsyncStream<(TransportMessage.WalkieTalkieControl, PeerInfo)>.Continuation
    private let announceContinuation: AsyncStream<(TransportMessage.ChannelAnnounce, PeerInfo)>.Continuation
    private let fileHeaderContinuation: AsyncStream<(TransportMessage.FileHeader, PeerInfo)>.Continuation
    private let fileChunkContinuation: AsyncStream<(TransportMessage.FileChunk, PeerInfo)>.Continuation
    private let audioContinuation: AsyncStream<(Data, PeerInfo)>.Continuation
    private let fileContinuation: AsyncStream<FileTransferEvent>.Continuation
    private let peerContinuation: AsyncStream<PeerEvent>.Continuation

    // CoreBluetooth
    private var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!
    private var service: CBMutableService?
    private var writeCharacteristic: CBMutableCharacteristic?
    private var peerNameCharacteristic: CBMutableCharacteristic?

    // Peer tracking — keyed by STABLE peer ID (from peer name characteristic)
    private var bleToStableID: [String: String] = [:]
    private var peersByStableID: [String: PeerInfo] = [:]
    private var peripheralsByStableID: [String: CBPeripheral] = [:]
    private var writeCharacteristics: [CBPeripheral: CBCharacteristic] = [:]
    private var centralToStableID: [UUID: String] = [:]
    private var reassemblyBuffers: [String: Data] = [:]

    // MARK: - Init

    init(displayName: String) {
        self.localPeer = PeerInfo(id: UUID().uuidString, displayName: displayName)
        (self.textMessages, self.textContinuation) = AsyncStream.makeStream()
        (self.controlMessages, self.controlContinuation) = AsyncStream.makeStream()
        (self.channelAnnouncements, self.announceContinuation) = AsyncStream.makeStream()
        (self.fileHeaders, self.fileHeaderContinuation) = AsyncStream.makeStream()
        (self.fileChunks, self.fileChunkContinuation) = AsyncStream.makeStream()
        (self.audioData, self.audioContinuation) = AsyncStream.makeStream()
        (self.fileTransfers, self.fileContinuation) = AsyncStream.makeStream()
        (self.peerEvents, self.peerContinuation) = AsyncStream.makeStream()
        super.init()
    }

    deinit {
        stop()
        textContinuation.finish(); controlContinuation.finish()
        announceContinuation.finish(); fileHeaderContinuation.finish(); fileChunkContinuation.finish()
        audioContinuation.finish(); fileContinuation.finish(); peerContinuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        centralManager = CBCentralManager(delegate: self, queue: nil)
        Logger.transport.info("BLE transport starting as \(self.localPeer.displayName) [\(self.localPeer.id.prefix(8))]")
    }

    func stop() {
        centralManager?.stopScan()
        for p in peripheralsByStableID.values { centralManager?.cancelPeripheralConnection(p) }
        peripheralManager?.stopAdvertising()
        if let svc = service { peripheralManager?.remove(svc) }
        discoveredPeers.removeAll(); connectedPeers.removeAll()
        bleToStableID.removeAll(); peersByStableID.removeAll()
        peripheralsByStableID.removeAll(); writeCharacteristics.removeAll()
        centralToStableID.removeAll(); reassemblyBuffers.removeAll()
        Logger.transport.info("BLE transport stopped")
    }

    func invitePeer(_ peer: PeerInfo) {
        // Auto-connect handles this — no-op
    }

    // MARK: - Send (central writes only — no notifications)

    func send(_ message: TransportMessage, to peers: [PeerInfo]) throws {
        let encoded = try JSONEncoder().encode(message)
        var payload = Data([DataTag.message.rawValue])
        payload.append(encoded)
        for peripheral in resolveTargets(peers) {
            writeChunked(payload, to: peripheral)
        }
    }

    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws {
        var payload = Data([DataTag.audio.rawValue])
        payload.append(data)
        for peripheral in resolveTargets(peers) {
            writeDirect(payload, to: peripheral)
        }
    }

    @discardableResult
    func sendFile(at url: URL, named: String, to peer: PeerInfo) -> Progress {
        Logger.transport.warning("BLE file transfer not supported")
        return Progress(totalUnitCount: 0)
    }

    // MARK: - Write Helpers

    private func writeDirect(_ data: Data, to peripheral: CBPeripheral) {
        guard let ch = writeCharacteristics[peripheral] else { return }
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if data.count <= mtu {
            peripheral.writeValue(data, for: ch, type: .withoutResponse)
        } else {
            var offset = 0
            while offset < data.count {
                let end = min(offset + mtu, data.count)
                peripheral.writeValue(data[offset..<end], for: ch, type: .withoutResponse)
                offset = end
            }
        }
    }

    private func writeChunked(_ data: Data, to peripheral: CBPeripheral) {
        guard let ch = writeCharacteristics[peripheral] else { return }
        let mtu = max(peripheral.maximumWriteValueLength(for: .withResponse) - 1, 20)

        if data.count <= mtu {
            var framed = Data([0x03]) // single
            framed.append(data)
            peripheral.writeValue(framed, for: ch, type: .withResponse)
            return
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            let flag: UInt8 = offset == 0 ? 0x01 : (end == data.count ? 0x02 : 0x00)
            var chunk = Data([flag])
            chunk.append(data[offset..<end])
            peripheral.writeValue(chunk, for: ch, type: .withResponse)
            offset = end
        }
    }

    // MARK: - Receive

    private func handleReceivedData(_ data: Data, from peerID: String) {
        guard let peer = peersByStableID[peerID] else {
            Logger.transport.warning("Data from unknown peer \(peerID.prefix(8))")
            return
        }
        guard data.count > 1, let tag = DataTag(rawValue: data[0]) else { return }

        if tag == .audio {
            audioContinuation.yield((data.subdata(in: 1..<data.count), peer))
            return
        }

        // Message with chunk framing
        guard data.count > 2 else { return }
        let flag = data[1]
        let payload = data.subdata(in: 2..<data.count)

        if flag == 0x03 { // single
            decodeMessage(payload, from: peer)
        } else if flag == 0x01 { // first
            reassemblyBuffers[peerID] = payload
        } else {
            reassemblyBuffers[peerID, default: Data()].append(payload)
            if flag == 0x02 { // last
                if let assembled = reassemblyBuffers.removeValue(forKey: peerID) {
                    decodeMessage(assembled, from: peer)
                }
            }
        }
    }

    private func decodeMessage(_ data: Data, from peer: PeerInfo) {
        guard let message = try? JSONDecoder().decode(TransportMessage.self, from: data) else {
            Logger.transport.error("Failed to decode message from \(peer.displayName)")
            return
        }
        switch message {
        case .text(let p): textContinuation.yield((p, peer))
        case .walkieTalkieControl(let c): controlContinuation.yield((c, peer))
        case .channelAnnounce(let a): announceContinuation.yield((a, peer))
        case .fileHeader(let h): fileHeaderContinuation.yield((h, peer))
        case .fileChunk(let c): fileChunkContinuation.yield((c, peer))
        }
    }

    // MARK: - Peer Identity

    private var peerNameData: Data {
        "\(localPeer.id)|\(localPeer.displayName)".data(using: .utf8) ?? Data()
    }

    private func parsePeerName(_ data: Data) -> (id: String, name: String)? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let parts = str.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func registerPeer(stableID: String, displayName: String, bleIdentifier: String, peripheral: CBPeripheral?) {
        guard stableID != localPeer.id else {
            Logger.transport.debug("Skipping self [\(stableID.prefix(8))]")
            if let p = peripheral { centralManager?.cancelPeripheralConnection(p) }
            return
        }
        if peersByStableID[stableID] != nil {
            Logger.transport.debug("Already know peer \(displayName) [\(stableID.prefix(8))]")
            bleToStableID[bleIdentifier] = stableID
            return
        }

        let peer = PeerInfo(id: stableID, displayName: displayName)
        bleToStableID[bleIdentifier] = stableID
        peersByStableID[stableID] = peer
        if let p = peripheral { peripheralsByStableID[stableID] = p }

        if peripheral != nil && writeCharacteristics[peripheral!] != nil {
            if !connectedPeers.contains(peer) { connectedPeers.append(peer) }
            discoveredPeers.removeAll { $0.id == stableID }
            peerContinuation.yield(.connected(peer))
            Logger.transport.info("Connected: \(displayName) [\(stableID.prefix(8))]")
        } else {
            if !discoveredPeers.contains(peer) && !connectedPeers.contains(peer) {
                discoveredPeers.append(peer)
            }
            peerContinuation.yield(.discovered(peer))
            Logger.transport.info("Discovered: \(displayName) [\(stableID.prefix(8))]")
        }
    }

    private func markConnected(stableID: String) {
        guard let peer = peersByStableID[stableID] else { return }
        if !connectedPeers.contains(peer) { connectedPeers.append(peer) }
        discoveredPeers.removeAll { $0.id == stableID }
        peerContinuation.yield(.connected(peer))
    }

    private func resolveTargets(_ peers: [PeerInfo]) -> [CBPeripheral] {
        let ids = peers.isEmpty ? Array(peripheralsByStableID.keys) : peers.map(\.id)
        return ids.compactMap { peripheralsByStableID[$0] }.filter { writeCharacteristics[$0] != nil }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLETransport: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            Logger.transport.warning("Peripheral state: \(peripheral.state.rawValue)")
            return
        }
        Task { @MainActor [weak self] in self?.setupService() }
    }

    private func setupService() {
        let writeCh = CBMutableCharacteristic(
            type: BLEConstants.dataWriteUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil, permissions: [.writeable]
        )
        let peerNameCh = CBMutableCharacteristic(
            type: BLEConstants.peerNameUUID,
            properties: [.read],
            value: peerNameData, permissions: [.readable]
        )
        let svc = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        svc.characteristics = [writeCh, peerNameCh]
        self.writeCharacteristic = writeCh
        self.peerNameCharacteristic = peerNameCh
        self.service = svc
        peripheralManager.add(svc)
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { Logger.transport.error("Add service failed: \(error.localizedDescription)"); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
                CBAdvertisementDataLocalNameKey: self.localPeer.displayName
            ])
            Logger.transport.info("Advertising started")
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for request in requests {
                guard let data = request.value else {
                    self.peripheralManager.respond(to: request, withResult: .invalidOffset)
                    continue
                }
                let centralUUID = request.central.identifier
                if let stableID = self.centralToStableID[centralUUID] {
                    self.handleReceivedData(data, from: stableID)
                } else {
                    Logger.transport.debug("Write from unknown central \(centralUUID.uuidString.prefix(8)), \(data.count) bytes")
                }
                self.peripheralManager.respond(to: request, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if request.characteristic.uuid == BLEConstants.peerNameUUID {
                request.value = self.peerNameData
                self.peripheralManager.respond(to: request, withResult: .success)
                let centralUUID = request.central.identifier
                Logger.transport.info("Central \(centralUUID.uuidString.prefix(8)) read our peer name")
            } else {
                self.peripheralManager.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            Logger.transport.warning("Central state: \(central.state.rawValue)")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.centralManager.scanForPeripherals(
                withServices: [BLEConstants.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            Logger.transport.info("Scanning started")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleID = peripheral.identifier.uuidString
            guard self.bleToStableID[bleID] == nil else { return }
            // MUST retain the peripheral before connecting — CoreBluetooth
            // cancels the connection if the CBPeripheral is deallocated.
            self.peripheralsByStableID[bleID] = peripheral // temporary key until we get stable ID
            self.centralManager.connect(peripheral, options: nil)
            Logger.transport.info("Auto-connecting to \(bleID.prefix(8))")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            peripheral.delegate = self
            peripheral.discoverServices([BLEConstants.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        Logger.transport.error("Connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleID = peripheral.identifier.uuidString
            if let stableID = self.bleToStableID.removeValue(forKey: bleID),
               let peer = self.peersByStableID.removeValue(forKey: stableID) {
                self.connectedPeers.removeAll { $0.id == stableID }
                self.peripheralsByStableID.removeValue(forKey: stableID)
                self.writeCharacteristics.removeValue(forKey: peripheral)
                self.peerContinuation.yield(.disconnected(peer))
                Logger.transport.info("Disconnected: \(peer.displayName)")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let services = peripheral.services else { return }
        for svc in services where svc.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics([BLEConstants.dataWriteUUID, BLEConstants.peerNameUUID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let chars = service.characteristics else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for ch in chars {
                if ch.uuid == BLEConstants.dataWriteUUID {
                    self.writeCharacteristics[peripheral] = ch
                } else if ch.uuid == BLEConstants.peerNameUUID {
                    peripheral.readValue(for: ch)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == BLEConstants.peerNameUUID, let data = characteristic.value else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let parsed = self.parsePeerName(data) else { return }
            let bleID = peripheral.identifier.uuidString
            self.registerPeer(stableID: parsed.id, displayName: parsed.name, bleIdentifier: bleID, peripheral: peripheral)

            if self.writeCharacteristics[peripheral] != nil {
                self.markConnected(stableID: parsed.id)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error { Logger.transport.error("Write failed: \(error.localizedDescription)") }
    }
}
