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
    var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!
    private var service: CBMutableService?
    private var writeCharacteristic: CBMutableCharacteristic?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var peerNameCharacteristic: CBMutableCharacteristic?
    private var audioPSMCharacteristic: CBMutableCharacteristic?

    /// L2CAP audio streaming (high bandwidth pipe for audio)
    let l2capAudio = L2CAPAudioStream()

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
        let targets = resolveTargets(peers)
        if !targets.isEmpty {
            for peripheral in targets {
                writeChunked(payload, to: peripheral)
            }
        }
        // Always also notify subscribed centrals (covers the case where
        // our central connection failed but their central connected to us)
        notifySubscribers(payload)
    }

    func sendAudioData(_ data: Data, to peers: [PeerInfo]) throws {
        // Prefer L2CAP for audio (high bandwidth). Fall back to GATT if no L2CAP channels.
        if l2capAudio.publishedPSM != 0 {
            l2capAudio.writeAudio(data)
            return
        }
        // GATT fallback (low bandwidth, choppy)
        var payload = Data([DataTag.audio.rawValue])
        payload.append(data)
        let targets = resolveTargets(peers)
        for peripheral in targets {
            writeDirect(payload, to: peripheral)
        }
        notifySubscribers(payload)
    }

    /// Send data to all centrals subscribed to our notify characteristic.
    private func notifySubscribers(_ data: Data) {
        guard let ch = notifyCharacteristic else { return }
        let maxPayload = 500 // conservative for BLE notifications

        if data.count + 1 <= maxPayload {
            // Fits in one notification
            var framed = Data([0x03]) // SINGLE
            framed.append(data)
            peripheralManager.updateValue(framed, for: ch, onSubscribedCentrals: nil)
        } else {
            // Split with FIRST/CONTINUATION/LAST framing
            var offset = 0
            while offset < data.count {
                let end = min(offset + maxPayload, data.count)
                let isFirst = offset == 0
                let isLast = end == data.count
                let flag: UInt8 = isFirst && isLast ? 0x03 : (isFirst ? 0x01 : (isLast ? 0x02 : 0x00))
                var chunk = Data([flag])
                chunk.append(data[offset..<end])
                peripheralManager.updateValue(chunk, for: ch, onSubscribedCentrals: nil)
                offset = end
            }
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
        // Always add CHUNK_FLAG_SINGLE (0x03) — without it, DataTag.audio (0x02)
        // gets misinterpreted as CHUNK_FLAG_LAST on the receiver.
        var framed = Data([0x03])
        framed.append(data)
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if framed.count <= mtu {
            peripheral.writeValue(framed, for: ch, type: .withoutResponse)
        } else {
            // Split into MTU-sized writes, each with SINGLE flag
            // (audio chunks are independent, no reassembly needed)
            var offset = 0
            let payload = data // without the flag we'll add per chunk
            while offset < payload.count {
                let end = min(offset + mtu - 1, payload.count)
                var chunk = Data([0x03])
                chunk.append(payload[offset..<end])
                peripheral.writeValue(chunk, for: ch, type: .withoutResponse)
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

    /// Handles raw BLE data. Format: [ChunkFlag][DataTag][payload]
    /// ChunkFlag: 0x03=single, 0x01=first, 0x00=continuation, 0x02=last
    private func handleReceivedData(_ rawData: Data, from peerID: String) {
        guard let peer = peersByStableID[peerID] else {
            Logger.transport.warning("Data from unknown peer \(peerID.prefix(8))")
            return
        }
        guard rawData.count >= 2 else { return }

        let firstByte = rawData[0]

        // Check if data has chunk framing (first byte is a chunk flag)
        if firstByte == 0x03 || firstByte == 0x01 || firstByte == 0x02 || firstByte == 0x00 {
            let innerData = rawData.subdata(in: 1..<rawData.count)

            if firstByte == 0x03 { // single — complete message
                processCompletePacket(innerData, from: peer)
            } else if firstByte == 0x01 { // first chunk
                reassemblyBuffers[peerID] = innerData
            } else if firstByte == 0x00 { // continuation
                reassemblyBuffers[peerID, default: Data()].append(innerData)
            } else if firstByte == 0x02 { // last chunk
                reassemblyBuffers[peerID, default: Data()].append(innerData)
                if let assembled = reassemblyBuffers.removeValue(forKey: peerID) {
                    processCompletePacket(assembled, from: peer)
                }
            }
        } else {
            // No chunk framing — raw [DataTag][payload]
            processCompletePacket(rawData, from: peer)
        }
    }

    /// Process a fully assembled packet: [DataTag][payload]
    private func processCompletePacket(_ data: Data, from peer: PeerInfo) {
        guard data.count > 1, let tag = DataTag(rawValue: data[0]) else {
            Logger.transport.warning("Bad packet from \(peer.displayName): \(data.count) bytes, first=\(data.first ?? 0)")
            return
        }
        let payload = data.subdata(in: 1..<data.count)

        if tag == .audio {
            audioContinuation.yield((payload, peer))
        } else {
            decodeMessage(payload, from: peer)
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
        let notifyCh = CBMutableCharacteristic(
            type: BLEConstants.dataNotifyUUID,
            properties: [.notify],
            value: nil, permissions: [.readable]
        )
        let peerNameCh = CBMutableCharacteristic(
            type: BLEConstants.peerNameUUID,
            properties: [.read],
            value: peerNameData, permissions: [.readable]
        )
        let psmCh = CBMutableCharacteristic(
            type: BLEConstants.audioPSMUUID,
            properties: [.read],
            value: nil, // Updated dynamically when L2CAP publishes
            permissions: [.readable]
        )
        let svc = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        svc.characteristics = [writeCh, notifyCh, peerNameCh, psmCh]
        self.writeCharacteristic = writeCh
        self.notifyCharacteristic = notifyCh
        self.peerNameCharacteristic = peerNameCh
        self.audioPSMCharacteristic = psmCh
        self.service = svc
        peripheralManager.add(svc)
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { Logger.transport.error("Add service failed: \(error.localizedDescription)"); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Only include service UUID — adding the name can overflow the 31-byte
            // BLE advertisement and push the UUID to scan response where Android won't find it
            self.peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID]
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
                    // Register this central immediately so its data isn't dropped
                    let tempID = centralUUID.uuidString
                    let peer = PeerInfo(id: tempID, displayName: "BLE-\(tempID.prefix(4))")
                    self.centralToStableID[centralUUID] = tempID
                    self.peersByStableID[tempID] = peer
                    if !self.connectedPeers.contains(peer) {
                        self.connectedPeers.append(peer)
                        self.peerContinuation.yield(.connected(peer))
                    }
                    self.handleReceivedData(data, from: tempID)
                    Logger.transport.info("Registered unknown central \(tempID.prefix(8)) and processed \(data.count) bytes")
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
                Logger.transport.info("Central \(request.central.identifier.uuidString.prefix(8)) read our peer name")
            } else if request.characteristic.uuid == BLEConstants.audioPSMUUID {
                // Return L2CAP PSM number as UInt16 little-endian
                var psm = self.l2capAudio.publishedPSM
                request.value = Data(bytes: &psm, count: 2)
                self.peripheralManager.respond(to: request, withResult: .success)
                Logger.transport.info("Central read audio PSM: \(psm)")
            } else {
                self.peripheralManager.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }

    // L2CAP delegate hooks
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.l2capAudio.didPublishL2CAPChannel(psm: PSM, error: error)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        if let error {
            Logger.transport.error("L2CAP channel open error: \(error.localizedDescription)")
            return
        }
        guard let channel else { return }
        Task { @MainActor [weak self] in
            self?.l2capAudio.handleChannelOpened(channel)
            Logger.transport.info("L2CAP: incoming channel opened (PSM=\(channel.psm))")
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
            // Scan for ALL peripherals — service UUID filtering can fail cross-platform.
            // We check the service UUID after connecting during service discovery.
            self.centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            Logger.transport.info("BLE scanning started (no filter)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleID = peripheral.identifier.uuidString
            guard self.bleToStableID[bleID] == nil else { return }

            // Check if advertisement contains our service UUID
            let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let isOurApp = serviceUUIDs.contains(BLEConstants.serviceUUID)

            if !isOurApp {
                return // Not our app, skip
            }

            // Retain and connect
            self.peripheralsByStableID[bleID] = peripheral
            self.centralManager.connect(peripheral, options: nil)
            Logger.transport.info("Found our app! Connecting to \(bleID.prefix(8)), services=\(serviceUUIDs)")
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
            peripheral.discoverCharacteristics([BLEConstants.dataWriteUUID, BLEConstants.peerNameUUID, BLEConstants.audioPSMUUID], for: svc)
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
                } else if ch.uuid == BLEConstants.audioPSMUUID {
                    peripheral.readValue(for: ch) // Read PSM for L2CAP audio
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        // Handle L2CAP PSM read
        if characteristic.uuid == BLEConstants.audioPSMUUID, let data = characteristic.value, data.count >= 2 {
            let psm = data.withUnsafeBytes { $0.load(as: UInt16.self) }
            if psm > 0 {
                Task { @MainActor [weak self] in
                    self?.l2capAudio.connectToChannel(on: peripheral, psm: psm)
                }
            }
            return
        }

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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        if let error {
            Logger.transport.error("L2CAP open failed: \(error.localizedDescription)")
            return
        }
        guard let channel else { return }
        Task { @MainActor [weak self] in
            self?.l2capAudio.handleChannelOpened(channel)
            Logger.transport.info("L2CAP: outgoing channel opened to \(peripheral.identifier.uuidString.prefix(8))")
        }
    }
}
