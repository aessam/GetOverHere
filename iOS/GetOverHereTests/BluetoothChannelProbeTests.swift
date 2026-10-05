import CoreBluetooth
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// Explicit native-open experiment, not admission/media qualification. Each style changes
/// only how the same production CoreBluetooth open queue is called on one discovered PSM.
@MainActor
struct BluetoothChannelProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOH_BLE_PROBE_STYLE"] != nil))
    func nativeChannelsOpenOnOnePeripheral() async throws {
        #if targetEnvironment(simulator)
        throw ProbeFailure.physicalDeviceRequired
        #else
        let environment = ProcessInfo.processInfo.environment
        let style = try #require(environment["GOH_BLE_PROBE_STYLE"])
        try #require(["queued", "sequential", "after_close", "distinct_psms"].contains(style))
        let room = try #require(environment["GOH_NEARBY_ROOM"].flatMap(UUID.init(uuidString:)))
        if style == "distinct_psms" {
            try await distinctPSMs(room: room)
            return
        }
        let radio = BluetoothRoomDiscovery()
        let state = ProbeState()
        defer { state.channels.forEach { $0.close() }; radio.stop() }
        radio.setMode(.browsing)
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !radio.canConnect(roomID: room) {
            try #require(ContinuousClock.now < discoveryDeadline, "Bluetooth probe endpoint was not discovered")
            try await Task.sleep(for: .milliseconds(50))
        }
        radio.setJoinedRoom(room)
        print("GOH_BLE_OPEN_PROBE style=\(style) endpoint=ready")

        // Raw channels intentionally send no lane selector. Complete before the guide's
        // ten-second bootstrap deadline; a stuck native open fails rather than being retried.
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            print("GOH_BLE_OPEN_PROBE style=\(style) deadline=exceeded")
            state.timedOut = true
            radio.stop()
        }
        defer { deadline.cancel() }
        let started = ContinuousClock.now
        func attempt(_ number: Int) async {
            print("GOH_BLE_OPEN_PROBE style=\(style) request=\(number) event=start")
            do {
                let channel = try await radio.connect(roomID: room)
                state.channels.append(channel)
                state.totalOpened += 1
                print("GOH_BLE_OPEN_PROBE style=\(style) request=\(number) event=opened elapsed=\(started.duration(to: .now))")
            } catch {
                let native = error as NSError
                print("GOH_BLE_OPEN_PROBE style=\(style) request=\(number) event=failed domain=\(native.domain) code=\(native.code)")
                state.failures += 1
            }
        }

        let expected = style == "after_close" ? 2 : 3
        if style == "queued" {
            // All callers enter before the first delegate completion; production didOpen
            // advances pending requests from within that CoreBluetooth callback.
            let calls = (1...expected).map { number in Task { @MainActor in await attempt(number) } }
            for call in calls { await call.value }
        } else {
            for number in 1...expected {
                // Await returns only after the previous delegate callback has returned.
                await attempt(number)
                if style == "after_close", number == 1 {
                    if !state.channels.isEmpty {
                        state.channels.removeFirst().close()
                        print("GOH_BLE_OPEN_PROBE style=\(style) request=1 event=closed-and-released")
                    }
                    // Experiment-only settling: CoreBluetooth has no public channel-close
                    // completion callback. Release the wrapper before allowing close processing.
                    // This delay is not a production workaround or a retry policy.
                    print("GOH_BLE_OPEN_PROBE style=\(style) close-settle-ms=300")
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        try #require(!state.timedOut, "Native open sequence exceeded three seconds")
        #expect(state.failures == 0)
        #expect(state.totalOpened == expected)
        #expect(state.channels.count == (style == "after_close" ? 1 : expected))
        print("GOH_BLE_OPEN_PROBE style=\(style) opened=\(state.totalOpened) expected=\(expected) active=\(state.channels.count) failures=\(state.failures)")
        #endif
    }

    private final class ProbeState {
        var channels: [any NearbyByteConnection] = []
        var totalOpened = 0
        var failures = 0
        var timedOut = false
    }

    private func distinctPSMs(room: UUID) async throws {
        let peer = DistinctPSMPeer(room: room)
        var channels: [NearbyBluetoothConnection] = []
        defer { channels.forEach { $0.close() }; peer.stop() }
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while peer.psms.isEmpty {
            if let failure = peer.failure { throw failure }
            try #require(ContinuousClock.now < discoveryDeadline, "Distinct-PSM endpoint was not discovered")
            try await Task.sleep(for: .milliseconds(50))
        }
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            print("GOH_BLE_OPEN_PROBE style=distinct_psms deadline=exceeded")
            peer.stop()
        }
        defer { deadline.cancel() }
        let started = ContinuousClock.now
        for (index, psm) in peer.psms.enumerated() {
            print("GOH_BLE_OPEN_PROBE style=distinct_psms request=\(index + 1) psm=\(psm) event=start")
            do {
                let channel = try await peer.open(psm)
                try #require(channel.psm == psm, "Native channel returned another PSM")
                channels.append(NearbyBluetoothConnection(channel))
                print("GOH_BLE_OPEN_PROBE style=distinct_psms request=\(index + 1) psm=\(channel.psm) event=opened elapsed=\(started.duration(to: .now))")
            } catch {
                let native = error as NSError
                print("GOH_BLE_OPEN_PROBE style=distinct_psms request=\(index + 1) event=failed domain=\(native.domain) code=\(native.code)")
                throw error
            }
        }
        #expect(channels.count == 3)
        print("GOH_BLE_OPEN_PROBE style=distinct_psms opened=\(channels.count) expected=3 active=\(channels.count)")
    }

    /// Test-only discovery contract. Production GOR2/PSM metadata is unchanged.
    private final class DistinctPSMPeer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
        private static let psmsID = CBUUID(string: "A1B2C3D4-0008-0000-0000-000000000000")
        private let room: UUID
        private var central: CBCentralManager?
        private var peripheral: CBPeripheral?
        private var psmsCharacteristic: CBCharacteristic?
        private var pendingOpen: CheckedContinuation<CBL2CAPChannel, any Error>?
        var psms: [CBL2CAPPSM] = []
        var failure: (any Error)?

        init(room: UUID) {
            self.room = room
            super.init()
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }

        func stop() {
            pendingOpen?.resume(throwing: ProbeFailure.closed)
            pendingOpen = nil
            central?.stopScan()
            if let peripheral { central?.cancelPeripheralConnection(peripheral); peripheral.delegate = nil }
            peripheral = nil
            central?.delegate = nil
            central = nil
        }

        func open(_ psm: CBL2CAPPSM) async throws -> CBL2CAPChannel {
            guard let peripheral, pendingOpen == nil else { throw ProbeFailure.closed }
            return try await withCheckedThrowingContinuation { continuation in
                pendingOpen = continuation
                peripheral.openL2CAPChannel(psm)
            }
        }

        func centralManagerDidUpdateState(_ manager: CBCentralManager) {
            guard manager === central else { return }
            switch manager.state {
            case .poweredOn: manager.scanForPeripherals(withServices: [BluetoothRoomDiscovery.serviceID])
            case .unknown, .resetting: break
            default: failure = ProbeFailure.unavailable
            }
        }

        func centralManager(_ manager: CBCentralManager, didDiscover peer: CBPeripheral,
                            advertisementData: [String: Any], rssi: NSNumber) {
            guard manager === central, peripheral == nil else { return }
            peripheral = peer
            manager.stopScan()
            peer.delegate = self
            manager.connect(peer)
        }

        func centralManager(_ manager: CBCentralManager, didConnect peer: CBPeripheral) {
            guard peer === peripheral else { return }
            peer.discoverServices([BluetoothRoomDiscovery.serviceID])
        }

        func centralManager(_ manager: CBCentralManager, didFailToConnect peer: CBPeripheral, error: Error?) {
            guard peer === peripheral else { return }
            failure = error ?? ProbeFailure.unavailable
        }

        func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peer: CBPeripheral, error: Error?) {
            guard peer === peripheral else { return }
            let cause = error ?? ProbeFailure.closed
            failure = cause
            pendingOpen?.resume(throwing: cause)
            pendingOpen = nil
        }

        func peripheral(_ peer: CBPeripheral, didDiscoverServices error: Error?) {
            guard peer === peripheral else { return }
            guard error == nil, let service = peer.services?.first(where: { $0.uuid == BluetoothRoomDiscovery.serviceID }) else {
                failure = error ?? ProbeFailure.invalidMetadata; return
            }
            peer.discoverCharacteristics([BluetoothRoomDiscovery.recordID, Self.psmsID], for: service)
        }

        func peripheral(_ peer: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            guard peer === peripheral else { return }
            guard error == nil,
                  let record = service.characteristics?.first(where: { $0.uuid == BluetoothRoomDiscovery.recordID }),
                  let selectors = service.characteristics?.first(where: { $0.uuid == Self.psmsID }) else {
                failure = error ?? ProbeFailure.invalidMetadata; return
            }
            psmsCharacteristic = selectors
            peer.readValue(for: record)
        }

        func peripheral(_ peer: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            guard peer === peripheral else { return }
            do {
                if let error { throw error }
                guard let bytes = characteristic.value else { throw ProbeFailure.invalidMetadata }
                if characteristic.uuid == BluetoothRoomDiscovery.recordID {
                    guard try BluetoothRoomRecord.decode(bytes).roomID == room,
                          let psmsCharacteristic else { throw ProbeFailure.invalidMetadata }
                    peer.readValue(for: psmsCharacteristic)
                } else if characteristic.uuid == Self.psmsID {
                    guard bytes.count == 6 else { throw ProbeFailure.invalidMetadata }
                    let values = stride(from: 0, to: 6, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
                    guard Set(values).count == 3, !values.contains(0) else { throw ProbeFailure.invalidMetadata }
                    psms = values
                }
            } catch { failure = error }
        }

        func peripheral(_ peer: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
            guard peer === peripheral, let continuation = pendingOpen else {
                channel?.inputStream.close(); channel?.outputStream.close(); return
            }
            pendingOpen = nil
            if let channel, error == nil { continuation.resume(returning: channel) }
            else {
                channel?.inputStream.close(); channel?.outputStream.close()
                continuation.resume(throwing: error ?? ProbeFailure.unavailable)
            }
        }
    }

    private enum ProbeFailure: Error { case physicalDeviceRequired, closed, unavailable, invalidMetadata }
}
