import CoreBluetooth
import Foundation
import os

/// BLE-based control plane. Handles discovery, commands, and coordination.
/// NO audio — only lightweight JSON metadata over GATT.
///
/// Each device is both peripheral (GATT server) and central (scanner + client).
/// Commands flow bidirectionally:
/// - Central writes → remote peripheral's commandWrite characteristic
/// - Peripheral notifies → remote central via commandNotify characteristic
@Observable
final class BLEControlPlane: NSObject, ControlPlane {
    let localPeer: PeerInfo
    private(set) var connectedPeers: [PeerInfo] = []

    let commands: AsyncStream<(BLECommand, PeerInfo)>
    let peerEvents: AsyncStream<PeerEvent>

    private let commandCont: AsyncStream<(BLECommand, PeerInfo)>.Continuation
    private let peerCont: AsyncStream<PeerEvent>.Continuation

    // CoreBluetooth
    private var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!
    private var service: CBMutableService?
    private var commandNotifyChar: CBMutableCharacteristic?

    // Peer tracking
    private var peripherals: [String: CBPeripheral] = [:]      // bleID → peripheral
    private var writeChars: [CBPeripheral: CBCharacteristic] = [:] // peripheral → write char
    private var peerByBLEID: [String: PeerInfo] = [:]          // bleID → peer
    private var centralPeers: [UUID: PeerInfo] = [:]           // central UUID → peer (server side)

    // MARK: - Init

    init(displayName: String) {
        self.localPeer = PeerInfo(displayName: displayName, platform: .ios)
        (commands, commandCont) = AsyncStream.makeStream()
        (peerEvents, peerCont) = AsyncStream.makeStream()
        super.init()
    }

    deinit { stop(); commandCont.finish(); peerCont.finish() }

    // MARK: - Lifecycle

    func start() {
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        centralManager = CBCentralManager(delegate: self, queue: nil)
        Logger.transport.info("BLE control plane starting")
    }

    func stop() {
        centralManager?.stopScan()
        peripherals.values.forEach { centralManager?.cancelPeripheralConnection($0) }
        peripheralManager?.stopAdvertising()
        if let svc = service { peripheralManager?.remove(svc) }
        connectedPeers.removeAll()
        peripherals.removeAll(); writeChars.removeAll()
        peerByBLEID.removeAll(); centralPeers.removeAll()
    }

    // MARK: - Send Commands

    func broadcast(_ command: BLECommand) {
        guard let data = encodeCommand(command) else { return }
        // Send via central writes to all connected peripherals
        for (_, peripheral) in peripherals {
            if let ch = writeChars[peripheral] {
                peripheral.writeValue(data, for: ch, type: .withResponse)
            }
        }
        // Also notify all subscribed centrals (bidirectional)
        if let ch = commandNotifyChar {
            peripheralManager?.updateValue(data, for: ch, onSubscribedCentrals: nil)
        }
    }

    func send(_ command: BLECommand, to peer: PeerInfo) {
        guard let data = encodeCommand(command) else { return }
        // Try central write
        if let peripheral = peripherals.values.first(where: { peerByBLEID[$0.identifier.uuidString]?.id == peer.id }),
           let ch = writeChars[peripheral] {
            peripheral.writeValue(data, for: ch, type: .withResponse)
        }
    }

    // MARK: - Encoding

    private func encodeCommand(_ command: BLECommand) -> Data? {
        try? JSONEncoder().encode(command)
    }

    private func decodeCommand(_ data: Data) -> BLECommand? {
        try? JSONDecoder().decode(BLECommand.self, from: data)
    }

    private var peerInfoData: Data {
        "\(localPeer.id)|\(localPeer.displayName)|\(localPeer.platform.rawValue)".data(using: .utf8) ?? Data()
    }

    private func parsePeerInfo(_ data: Data) -> PeerInfo? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let parts = str.split(separator: "|", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let platform = PeerInfo.Platform(rawValue: String(parts[2])) ?? .ios
        return PeerInfo(id: String(parts[0]), displayName: String(parts[1]), platform: platform)
    }

    private func registerPeer(_ peer: PeerInfo, bleID: String) {
        guard peer.id != localPeer.id else { return }
        peerByBLEID[bleID] = peer
        if !connectedPeers.contains(where: { $0.id == peer.id }) {
            connectedPeers.append(peer)
            peerCont.yield(.connected(peer))
            Logger.transport.info("Connected: \(peer.displayName) (\(peer.platform.rawValue))")
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEControlPlane: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        Task { @MainActor [weak self] in self?.setupService() }
    }

    private func setupService() {
        let writeCh = CBMutableCharacteristic(
            type: BLEConstants.commandWriteUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil, permissions: [.writeable]
        )
        let notifyCh = CBMutableCharacteristic(
            type: BLEConstants.commandNotifyUUID,
            properties: [.notify],
            value: nil, permissions: [.readable]
        )
        let peerInfoCh = CBMutableCharacteristic(
            type: BLEConstants.peerInfoUUID,
            properties: [.read],
            value: peerInfoData, permissions: [.readable]
        )
        let svc = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        svc.characteristics = [writeCh, notifyCh, peerInfoCh]
        commandNotifyChar = notifyCh
        service = svc
        peripheralManager.add(svc)
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { Logger.transport.error("GATT service add failed: \(error.localizedDescription)"); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID]
            ])
            Logger.transport.info("BLE advertising started")
        }
    }

    nonisolated func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for request in requests {
                guard let data = request.value else {
                    self.peripheralManager.respond(to: request, withResult: .invalidOffset)
                    continue
                }
                // Register central if unknown
                let centralUUID = request.central.identifier
                let peer = self.centralPeers[centralUUID] ?? PeerInfo(id: centralUUID.uuidString, displayName: "BLE-\(centralUUID.uuidString.prefix(4))")
                if self.centralPeers[centralUUID] == nil {
                    self.centralPeers[centralUUID] = peer
                    self.registerPeer(peer, bleID: centralUUID.uuidString)
                }
                // Decode and dispatch command
                if let cmd = self.decodeCommand(data) {
                    self.commandCont.yield((cmd, peer))
                }
                self.peripheralManager.respond(to: request, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManager(_ pm: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if request.characteristic.uuid == BLEConstants.peerInfoUUID {
                request.value = self.peerInfoData
                self.peripheralManager.respond(to: request, withResult: .success)
            } else {
                self.peripheralManager.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEControlPlane: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        Task { @MainActor [weak self] in
            self?.centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            Logger.transport.info("BLE scanning started")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleID = peripheral.identifier.uuidString
            guard self.peripherals[bleID] == nil else { return }
            let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            guard serviceUUIDs.contains(BLEConstants.serviceUUID) else { return }
            self.peripherals[bleID] = peripheral
            self.centralManager.connect(peripheral, options: nil)
            Logger.transport.info("Connecting to \(bleID.prefix(8))")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            peripheral.delegate = self
            peripheral.discoverServices([BLEConstants.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleID = peripheral.identifier.uuidString
            if let peer = self.peerByBLEID.removeValue(forKey: bleID) {
                self.connectedPeers.removeAll { $0.id == peer.id }
                self.peerCont.yield(.disconnected(peer))
            }
            self.peripherals.removeValue(forKey: bleID)
            self.writeChars.removeValue(forKey: peripheral)
            // Auto-reconnect
            self.centralManager.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEControlPlane: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let services = peripheral.services else { return }
        for svc in services where svc.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics(
                [BLEConstants.commandWriteUUID, BLEConstants.commandNotifyUUID, BLEConstants.peerInfoUUID],
                for: svc
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let chars = service.characteristics else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for ch in chars {
                if ch.uuid == BLEConstants.commandWriteUUID {
                    self.writeChars[peripheral] = ch
                } else if ch.uuid == BLEConstants.commandNotifyUUID {
                    peripheral.setNotifyValue(true, for: ch)
                } else if ch.uuid == BLEConstants.peerInfoUUID {
                    peripheral.readValue(for: ch)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleID = peripheral.identifier.uuidString
            if characteristic.uuid == BLEConstants.peerInfoUUID {
                if let peer = self.parsePeerInfo(data) {
                    self.registerPeer(peer, bleID: bleID)
                }
            } else if characteristic.uuid == BLEConstants.commandNotifyUUID {
                if let cmd = self.decodeCommand(data),
                   let peer = self.peerByBLEID[bleID] {
                    self.commandCont.yield((cmd, peer))
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error { Logger.transport.error("BLE write failed: \(error.localizedDescription)") }
    }
}
