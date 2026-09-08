import Foundation
import Network
import os
import TourSessionCore
import WiFiAware

let wiFiAwareRoomServiceName = "_goh-tour._tcp"

@available(iOS 26.4, *)
extension WAPublishableService {
    static var getOverHereRoom: WAPublishableService {
        guard let service = allServices[wiFiAwareRoomServiceName] else {
            preconditionFailure("Missing publishable tour service")
        }
        return service
    }
}

@available(iOS 26.4, *)
extension WASubscribableService {
    static var getOverHereRoom: WASubscribableService {
        guard let service = allServices[wiFiAwareRoomServiceName] else {
            preconditionFailure("Missing subscribable tour service")
        }
        return service
    }
}

/// Uses public Network APIs only. Cancelling pending operations releases the native connection.
@MainActor
@available(iOS 26.4, *)
final class NearbyAwareConnection: NearbyByteConnection {
    private var connection: NetworkConnection<TCP>?
    private var readTask: Task<Data, any Error>?
    private var writeTask: Task<Void, any Error>?
    init(_ connection: NetworkConnection<TCP>) { self.connection = connection }

    func read(maximum: Int) async throws -> Data {
        guard let connection else { throw NearbyConnectionError.closed }
        let task = Task { try await connection.receive(atLeast: 1, atMost: maximum).content }
        readTask = task
        defer { readTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func write(_ bytes: Data) async throws {
        guard let connection else { throw NearbyConnectionError.closed }
        let task = Task { try await connection.send(bytes) }
        writeTask = task
        defer { writeTask = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func close() {
        readTask?.cancel(); writeTask?.cancel()
        readTask = nil; writeTask = nil; connection = nil
    }
}

/// Production Aware endpoint owner. The room selector routes accepted connections
/// into real admission/realtime/control/asset lanes; the lab is not involved.
@MainActor
@available(iOS 26.4, *)
final class WiFiAwareRoomTransport: NearbyRoomTransport {
    var onRoom: ((BluetoothRoomRecord) -> Void)?
    var onLost: ((UUID) -> Void)?
    var onError: ((String) -> Void)?
    private var mode = BluetoothDiscoveryMode.off
    private var record: BluetoothRoomRecord?
    private let guideBridge = NearbySocketBridge()
    private var task: Task<Void, Never>?
    private var probes: [WAEndpoint: Task<Void, Never>] = [:]
    private var records: [WAEndpoint: BluetoothRoomRecord] = [:]
    private var endpoints: [UUID: WAEndpoint] = [:]
    private let supportsAware: () -> Bool
    private let maximumConnectableDevices: () -> Int?
    /// Device capability, not available paths and never proof of field group capacity.
    private(set) var maximumPeerCapacity: Int?
    private let operationOverride: ((BluetoothDiscoveryMode) async throws -> Void)?

    init(supportsAware: @escaping () -> Bool = { WACapabilities.supportedFeatures.contains(.wifiAware) },
         maximumConnectableDevices: @escaping () -> Int? = { WACapabilities.maximumConnectableDevices },
         operation: ((BluetoothDiscoveryMode) async throws -> Void)? = nil) {
        self.supportsAware = supportsAware
        self.maximumConnectableDevices = maximumConnectableDevices
        self.operationOverride = operation
    }

    func publish(_ record: BluetoothRoomRecord?) { self.record = record }

    func setMode(_ mode: BluetoothDiscoveryMode) {
        guard self.mode != mode else { return }
        stop()
        self.mode = mode
        guard mode != .off else { return }
        maximumPeerCapacity = nil
        guard supportsAware() else {
            stop()
            report("Wi-Fi Aware is unsupported on this device.")
            return
        }
        if let maximum = maximumConnectableDevices(), maximum >= 0 {
            maximumPeerCapacity = maximum
            Logger.transport.info("Wi-Fi Aware reports a maximum of \(maximum) unique peers; software listener bound is \(SessionCapacityPolicy.listenerLimit), hardware group capacity remains unqualified")
            guard maximum > 0 else {
                stop()
                report("Wi-Fi Aware reports no connectable peers on this device.")
                return
            }
        } else {
            maximumPeerCapacity = nil
            Logger.transport.warning("Wi-Fi Aware peer capacity is unknown; no thirty-peer claim")
        }
        guideBridge.onError = { [weak self] in self?.report($0) }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let operationOverride { try await operationOverride(mode) }
                else if mode == .advertising { try await runGuide() }
                else { try await runBrowser() }
                guard !Task.isCancelled else { return }
                // A native owner ending without cancellation is no longer a usable route.
                throw NearbyConnectionError.closed
            } catch {
                guard !Task.isCancelled else { return }
                stop()
                report(NearbyAwareFailure.message(for: error,
                    during: mode == .advertising ? .advertising : .browsing))
            }
        }
    }

    func stop() {
        mode = .off
        task?.cancel(); task = nil
        probes.values.forEach { $0.cancel() }; probes.removeAll()
        for id in endpoints.keys { onLost?(id) }
        endpoints.removeAll(); records.removeAll()
        guideBridge.stop()
    }

    func connect(roomID: UUID) async throws -> any NearbyByteConnection {
        guard let endpoint = endpoints[roomID] else { throw NearbyConnectionError.unavailable }
        return Self.connection(to: endpoint)
    }

    private static func connection(to endpoint: WAEndpoint) -> NearbyAwareConnection {
        NearbyAwareConnection(NetworkConnection(to: endpoint,
            using: .parameters { TCP() }.wifiAware { $0.performanceMode = .realtime }))
    }

    private func runGuide() async throws {
        let listener = try NetworkListener(
            for: .wifiAware(.connecting(to: .getOverHereRoom, from: .allPairedDevices, datapath: .realtime)),
            using: .parameters { TCP() }.wifiAware { $0.performanceMode = .realtime }
        )
        try await listener.run { [weak self] connection in
            guard let self else { return }
            guideBridge.accept(NearbyAwareConnection(connection)) { [weak self] in self?.record }
        }
    }

    private func runBrowser() async throws {
        let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: .getOverHereRoom)))
        try await browser.run { [weak self] (found: [WAEndpoint]) async throws -> Void in
            guard let self else { return }
            for endpoint in Array(probes.keys) where !found.contains(endpoint) {
                probes.removeValue(forKey: endpoint)?.cancel()
                if let old = records.removeValue(forKey: endpoint), endpoints[old.roomID] == endpoint {
                    endpoints.removeValue(forKey: old.roomID); onLost?(old.roomID)
                }
            }
            for endpoint in found where probes[endpoint] == nil && probes.count < 16 {
                probes[endpoint] = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            let current = try await NearbySocketBridge.readRecord { Self.connection(to: endpoint) }
                            guard let self, !Task.isCancelled else { return }
                            if let old = records[endpoint], old.roomID != current.roomID {
                                endpoints.removeValue(forKey: old.roomID); onLost?(old.roomID)
                            }
                            records[endpoint] = current; endpoints[current.roomID] = endpoint
                            onRoom?(current)
                        } catch {
                            guard let self, !Task.isCancelled else { return }
                            if let old = records.removeValue(forKey: endpoint) {
                                endpoints.removeValue(forKey: old.roomID); onLost?(old.roomID)
                            }
                            report(NearbyAwareFailure.message(for: error, during: .metadata))
                        }
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
            }
        }
    }

    private func report(_ message: String) {
        Logger.transport.error("Wi-Fi Aware operation failed")
        onError?(message)
    }
}
