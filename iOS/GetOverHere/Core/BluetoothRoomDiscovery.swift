import CoreBluetooth
import Foundation
import TourSessionCore
import os

protocol BluetoothRoomDiscoveryInterface: AnyObject {
    var onRoom: ((BluetoothRoomRecord) -> Void)? { get set }
    var onLost: ((UUID) -> Void)? { get set }
    func setMode(_ mode: BluetoothDiscoveryMode)
    func stop()
    func publish(_ record: BluetoothRoomRecord?)
}

protocol BluetoothSessionDiscoveryInterface: BluetoothRoomDiscoveryInterface {
    func canConnect(roomID: UUID) -> Bool
    func connect(roomID: UUID) async throws -> any NearbyByteConnection
    func setJoinedRoom(_ roomID: UUID?)
}

/// Read-only GATT discovery. This does not admit guests or carry tour payloads.
final class BluetoothRoomDiscovery: NSObject, BluetoothSessionDiscoveryInterface {
    static let serviceID = CBUUID(string: "A1B2C3D4-0005-0000-0000-000000000000")
    static let recordID = CBUUID(string: "A1B2C3D4-0006-0000-0000-000000000000")
    static let psmID = CBUUID(string: "A1B2C3D4-0007-0000-0000-000000000000")
    var onRoom: ((BluetoothRoomRecord) -> Void)?
    var onLost: ((UUID) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var running = false
    private var mode: BluetoothDiscoveryMode = .off
    private var scanTick = 0
    private var serviceReady = false
    private var record = Data()
    private var timer: Task<Void, Never>?
    private var links: [UUID: CBPeripheral] = [:]
    private var characteristics: [UUID: CBCharacteristic] = [:]
    private var pending: [UUID: Date] = [:]
    private var attempts: [UUID: Date] = [:]
    private var rooms: [UUID: (BluetoothRoomRecord, Date)] = [:]
    private var snapshots: [UUID: (Data, Date)] = [:]
    private var psm: CBL2CAPPSM = 0
    private var peerPSMs: [UUID: CBL2CAPPSM] = [:]
    private var psmCharacteristics: [UUID: CBCharacteristic] = [:]
    private var opens: [UUID: [CheckedContinuation<any NearbyByteConnection, any Error>]] = [:]
    private var joinedRoom: UUID?
    private var openingTokens: [UUID: UUID] = [:]
    private let sessionBridge = NearbySocketBridge()

    func canConnect(roomID: UUID) -> Bool {
        rooms.contains { id, room in room.0.roomID == roomID && peerPSMs[id] != nil && links[id] != nil }
    }
    func setJoinedRoom(_ roomID: UUID?) {
        joinedRoom = roomID
        if roomID != nil { central?.stopScan() }
        else if mode == .browsing, central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: [Self.serviceID])
        }
    }
    func connect(roomID: UUID) async throws -> any NearbyByteConnection {
        guard let id = rooms.first(where: { $0.value.0.roomID == roomID })?.key,
              let link = links[id], let remotePSM = peerPSMs[id] else { throw NearbyConnectionError.unavailable }
        guard opens[id, default: []].count < 4 else { throw NearbyConnectionError.capacity }
        return try await withCheckedThrowingContinuation { continuation in
            opens[id, default: []].append(continuation)
            if opens[id]?.count == 1 { openChannel(link, psm: remotePSM) }
        }
    }

    private func openChannel(_ link: CBPeripheral, psm: CBL2CAPPSM) {
        let id = link.identifier
        let token = UUID()
        openingTokens[id] = token
        link.openL2CAPChannel(psm)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, openingTokens[id] == token else { return }
            Logger.transport.error("Bluetooth session connection timed out")
            disconnect(id)
        }
    }

    func setMode(_ mode: BluetoothDiscoveryMode) {
        guard self.mode != mode else { return }
        let savedRecord = record
        stop()
        record = savedRecord
        self.mode = mode
        guard mode != .off else { return }
        running = true
        if mode == .browsing {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            peripheral = CBPeripheralManager(delegate: self, queue: .main,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        joinedRoom = nil; psm = 0; peerPSMs.removeAll(); psmCharacteristics.removeAll()
        sessionBridge.stop()
        openingTokens.removeAll()
        opens.values.flatMap { $0 }.forEach { $0.resume(throwing: NearbyConnectionError.closed) }; opens.removeAll()
        mode = .off; scanTick = 0
        running = false; record = Data(); timer?.cancel(); timer = nil
        central?.stopScan()
        for link in links.values { central?.cancelPeripheralConnection(link) }
        peripheral?.stopAdvertising(); peripheral?.removeAllServices()
        links.removeAll(); characteristics.removeAll(); pending.removeAll(); attempts.removeAll()
        for room in rooms.values { onLost?(room.0.roomID) }
        rooms.removeAll(); snapshots.removeAll(); serviceReady = false
        central?.delegate = nil; peripheral?.delegate = nil
        central = nil; peripheral = nil
    }

    func publish(_ value: BluetoothRoomRecord?) {
        do { record = try value?.encode() ?? Data() }
        catch { record = Data(); Logger.transport.error("Bluetooth room metadata rejected") }
        updateAdvertising()
    }

    private func updateAdvertising() {
        guard running, peripheral?.state == .poweredOn, serviceReady else { return }
        if record.isEmpty { peripheral?.stopAdvertising() }
        else if peripheral?.isAdvertising == false {
            peripheral?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
        }
    }

    private func refresh() {
        guard running else { return }
        if mode == .browsing, joinedRoom.map({ !canConnect(roomID: $0) }) ?? true,
           let central, central.state == .poweredOn {
            // Three seconds scanning, three seconds resting; duplicate delivery is unnecessary.
            scanTick += 1
            if scanTick % 2 == 1 { central.stopScan() }
            else { central.scanForPeripherals(withServices: [Self.serviceID]) }
        }
        let now = Date()
        for (id, since) in pending where now.timeIntervalSince(since) > 9 { disconnect(id) }
        for (id, ch) in characteristics where pending[id] == nil {
            pending[id] = now; links[id]?.readValue(for: ch)
        }
        for (id, room) in rooms where now.timeIntervalSince(room.1) > 12 {
            rooms.removeValue(forKey: id); onLost?(room.0.roomID)
        }
        attempts = attempts.filter { now.timeIntervalSince($0.value) < 12 }
        snapshots = snapshots.filter { now.timeIntervalSince($0.value.1) < 10 }
    }

    private func disconnect(_ id: UUID) {
        openingTokens.removeValue(forKey: id)
        peerPSMs.removeValue(forKey: id); psmCharacteristics.removeValue(forKey: id)
        opens.removeValue(forKey: id)?.forEach { $0.resume(throwing: NearbyConnectionError.closed) }
        if let link = links.removeValue(forKey: id) { central?.cancelPeripheralConnection(link) }
        characteristics.removeValue(forKey: id); pending.removeValue(forKey: id)
    }
}

extension BluetoothRoomDiscovery: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running, self.central === central else { return }
        if central.state == .poweredOn {
            scanTick = 0
            central.scanForPeripherals(withServices: [Self.serviceID])
            Logger.transport.info("Bluetooth room discovery scanning")
        } else {
            for id in Array(links.keys) { disconnect(id) }
            for room in rooms.values { onLost?(room.0.roomID) }
            rooms.removeAll()
            Logger.transport.notice("Bluetooth room discovery unavailable (state \(central.state.rawValue))")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover link: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard running, self.central === central, mode == .browsing, links.count < 4, links[link.identifier] == nil,
              attempts[link.identifier].map({ Date().timeIntervalSince($0) >= 6 }) ?? true else { return }
        attempts[link.identifier] = Date(); links[link.identifier] = link; pending[link.identifier] = Date()
        link.delegate = self; central.connect(link)
    }

    func centralManager(_ central: CBCentralManager, didConnect link: CBPeripheral) {
        guard running, links[link.identifier] === link else { central.cancelPeripheralConnection(link); return }
        link.discoverServices([Self.serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect link: CBPeripheral, error: Error?) {
        Logger.transport.error("Bluetooth room connection failed"); disconnect(link.identifier)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral link: CBPeripheral, error: Error?) {
        guard links[link.identifier] === link else { return }
        disconnect(link.identifier)
    }
    func peripheral(_ link: CBPeripheral, didDiscoverServices error: Error?) {
        guard running, links[link.identifier] === link, error == nil,
              let service = link.services?.first(where: { $0.uuid == Self.serviceID }) else {
            disconnect(link.identifier); return
        }
        link.discoverCharacteristics([Self.recordID, Self.psmID], for: service)
    }
    func peripheral(_ link: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard running, links[link.identifier] === link, error == nil,
              let ch = service.characteristics?.first(where: { $0.uuid == Self.recordID }) else {
            disconnect(link.identifier); return
        }
        psmCharacteristics[link.identifier] = service.characteristics?.first { $0.uuid == Self.psmID }
        characteristics[link.identifier] = ch; link.readValue(for: ch)
    }
    func peripheral(_ link: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == Self.psmID {
            guard running, links[link.identifier] === link else { return }
            pending.removeValue(forKey: link.identifier)
            if error == nil, let value = ch.value, value.count == 2 {
                let bytes = [UInt8](value)
                let value = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                if value != 0 { peerPSMs[link.identifier] = value }
                else { peerPSMs.removeValue(forKey: link.identifier) }
                if let joinedRoom, rooms[link.identifier]?.0.roomID == joinedRoom, value != 0 { central?.stopScan() }
                if let room = rooms[link.identifier]?.0 { onRoom?(room) }
            }
            return
        }
        guard running, links[link.identifier] === link, ch.uuid == Self.recordID else { return }
        pending.removeValue(forKey: link.identifier)
        guard error == nil, let data = ch.value else {
            Logger.transport.error("Bluetooth room read failed"); disconnect(link.identifier); return
        }
        if data.isEmpty {
            if let old = rooms.removeValue(forKey: link.identifier) { onLost?(old.0.roomID) }
            disconnect(link.identifier); return
        }
        do {
            let decoded = try BluetoothRoomRecord.decode(data)
            if let joinedRoom, decoded.roomID != joinedRoom { disconnect(link.identifier); return }
            if let old = rooms[link.identifier], old.0.roomID != decoded.roomID { onLost?(old.0.roomID) }
            rooms[link.identifier] = (decoded, Date()); onRoom?(decoded)
            if peerPSMs[link.identifier] == nil, let psmCharacteristic = psmCharacteristics[link.identifier] {
                pending[link.identifier] = Date(); link.readValue(for: psmCharacteristic)
            }
            Logger.transport.debug("Bluetooth room metadata received")
        } catch { Logger.transport.error("Invalid Bluetooth room record"); disconnect(link.identifier) }
    }

    func peripheral(_ link: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard var queued = opens[link.identifier], !queued.isEmpty else {
            channel?.inputStream.close(); channel?.outputStream.close(); return
        }
        let continuation = queued.removeFirst()
        openingTokens.removeValue(forKey: link.identifier)
        opens[link.identifier] = queued.isEmpty ? nil : queued
        if let channel, error == nil { continuation.resume(returning: NearbyBluetoothConnection(channel)) }
        else { continuation.resume(throwing: error ?? NearbyConnectionError.unavailable) }
        if !queued.isEmpty, let remotePSM = peerPSMs[link.identifier] { openChannel(link, psm: remotePSM) }
    }
}

extension BluetoothRoomDiscovery: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard running, peripheral === manager else { return }
        serviceReady = false
        guard manager.state == .poweredOn else { return }
        manager.removeAllServices()
        manager.publishL2CAPChannel(withEncryption: false) // GOH room admission and media AEAD remain mandatory.
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [Self.recordID, Self.psmID].map {
            CBMutableCharacteristic(type: $0, properties: [.read], value: nil, permissions: [.readable])
        }
        manager.add(service)
    }
    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        guard running, error == nil else { Logger.transport.error("Bluetooth room service failed"); return }
        serviceReady = true; updateAdvertising()
    }
    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        if error != nil { Logger.transport.error("Bluetooth room advertising failed") }
        else { Logger.transport.info("Bluetooth room advertising started") }
    }
    func peripheralManager(_ manager: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if running, request.characteristic.uuid == Self.psmID {
            guard request.offset <= 2 else { manager.respond(to: request, withResult: .invalidOffset); return }
            request.value = Data([UInt8(psm >> 8), UInt8(psm & 255)]).dropFirst(request.offset)
            manager.respond(to: request, withResult: .success); return
        }
        guard running, request.characteristic.uuid == Self.recordID else {
            manager.respond(to: request, withResult: .attributeNotFound); return
        }
        let id = request.central.identifier
        if request.offset == 0 {
            snapshots = snapshots.filter { Date().timeIntervalSince($0.value.1) < 10 }
            guard snapshots[id] != nil || snapshots.count < 16 else {
                manager.respond(to: request, withResult: .insufficientResources); return
            }
            snapshots[id] = (record, Date())
        }
        guard let bytes = snapshots[id]?.0, request.offset <= bytes.count else {
            manager.respond(to: request, withResult: .invalidOffset); return
        }
        request.value = bytes.subdata(in: request.offset..<bytes.count)
        manager.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ manager: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard peripheral === manager, running else { return }
        if error == nil { psm = PSM }
        else { Logger.transport.error("Bluetooth session listener unavailable") }
    }
    func peripheralManager(_ manager: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard peripheral === manager, running, mode == .advertising, error == nil, let channel else {
            channel?.inputStream.close(); channel?.outputStream.close(); return
        }
        sessionBridge.accept(NearbyBluetoothConnection(channel)) { [weak self] in
            guard let self, !record.isEmpty else { return nil }
            do { return try BluetoothRoomRecord.decode(record) }
            catch { Logger.transport.error("Hosted Bluetooth room record invalid"); return nil }
        }
    }
}
