import Foundation
import Network
import TourSessionCore

/// Native endpoints remain intact: service identity and scoped IPv6 are never
/// flattened into the LAN-only IPv4 discovery path. includePeerToPeer permits
/// AWDL; route evidence, not this flag, proves AP-free operation.
@MainActor
final class ApplePeerRoomTransport: NearbyRoomTransport {
    static let serviceType = "_goh-peer._tcp"
    var onRoom: ((BluetoothRoomRecord) -> Void)?
    var onLost: ((UUID) -> Void)?
    var onError: ((String) -> Void)?
    var onState: ((String) -> Void)?
    private(set) var endpoints: [UUID: NWEndpoint] = [:]
    private(set) var observedPaths: [UUID: [String: String]] = [:]
    private let bridge = NearbySocketBridge()
    private var record: BluetoothRoomRecord?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var probes: [NWEndpoint: Task<Void, Never>] = [:]
    private var records: [NWEndpoint: BluetoothRoomRecord] = [:]
    private var mode = BluetoothDiscoveryMode.off
    private var generation: UInt64 = 0

    var guideConnector: (any GuideLaneConnector)? {
        get { bridge.guideConnector }
        set {
            bridge.guideConnector = newValue
            bridge.audioResidenceMilliseconds = newValue == nil ? NearbyRealtimeQueue.lifetimeMilliseconds : GatewayProtocol.audioResidenceMilliseconds
        }
    }

    static func parameters() -> NWParameters {
        let parameters = NearbyTCPConnection.parameters()
        parameters.includePeerToPeer = true
        return parameters
    }

    func publish(_ record: BluetoothRoomRecord?) { self.record = record }

    func setMode(_ mode: BluetoothDiscoveryMode) {
        guard mode != self.mode else { return }
        stop(); self.mode = mode
        onState?(mode == .off ? "stopped" : "starting")
        let attempt = generation
        do {
            bridge.onError = { [weak self] in self?.onError?($0) }
            if mode == .advertising {
                let listener = try NWListener(using: Self.parameters())
                listener.service = NWListener.Service(name: UUID().uuidString, type: Self.serviceType)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == attempt else { connection.cancel(); return }
                        self.observe(connection, direction: "incoming")
                        self.bridge.accept(NearbyTCPConnection(connection)) { [weak self] in self?.record }
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == attempt else { return }
                        if case .ready = state { self.onState?("advertising") }
                        if case .failed(let error) = state { self.stop(); self.onError?(error.localizedDescription) }
                    }
                }
                self.listener = listener
                listener.start(queue: .main)
            } else if mode == .browsing {
                let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: Self.parameters())
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == attempt else { return }
                        self.update(Set(results.map(\.endpoint)))
                    }
                }
                browser.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == attempt else { return }
                        if case .ready = state { self.onState?("browsing") }
                        if case .failed(let error) = state { self.stop(); self.onError?(error.localizedDescription) }
                    }
                }
                self.browser = browser
                browser.start(queue: .main)
            }
        } catch { stop(); onError?(error.localizedDescription) }
    }

    private func update(_ found: Set<NWEndpoint>) {
        for endpoint in Set(probes.keys).subtracting(found) {
            probes.removeValue(forKey: endpoint)?.cancel()
            if let old = records.removeValue(forKey: endpoint), endpoints[old.roomID] == endpoint {
                endpoints.removeValue(forKey: old.roomID); onLost?(old.roomID)
            }
        }
        let attempt = generation
        for endpoint in found where probes[endpoint] == nil {
            guard probes.count < 64 else { onError?("Apple peer discovery capacity reached."); break }
            probes[endpoint] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, generation == attempt {
                    do {
                        let current = try await NearbySocketBridge.readRecord { Self.connection(endpoint) }
                        guard !Task.isCancelled, generation == attempt else { return }
                        if records[endpoint] != current {
                            if let old = records[endpoint], old.roomID != current.roomID {
                                endpoints.removeValue(forKey: old.roomID); onLost?(old.roomID)
                            }
                            records[endpoint] = current; endpoints[current.roomID] = endpoint; onRoom?(current)
                        }
                    } catch {
                        guard !Task.isCancelled, generation == attempt else { return }
                        if let old = records.removeValue(forKey: endpoint), endpoints[old.roomID] == endpoint {
                            endpoints.removeValue(forKey: old.roomID); onLost?(old.roomID)
                        }
                        onError?("Apple peer metadata failed: \(error.localizedDescription)")
                    }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }

    private static func connection(_ endpoint: NWEndpoint) -> NearbyTCPConnection {
        NearbyTCPConnection(NWConnection(to: endpoint, using: parameters()))
    }
    func connect(roomID: UUID) async throws -> any NearbyByteConnection {
        guard let endpoint = endpoints[roomID] else { throw NearbyConnectionError.unavailable }
        let connection = NWConnection(to: endpoint, using: Self.parameters())
        observe(connection, direction: "outgoing")
        return NearbyTCPConnection(connection)
    }
    private func observe(_ connection: NWConnection, direction: String) {
        let id = UUID(); let attempt = generation
        let endpoint = String(describing: connection.endpoint)
        if observedPaths.count >= 128, let oldest = observedPaths.keys.first { observedPaths.removeValue(forKey: oldest) }
        connection.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, generation == attempt else { return }
                observedPaths[id] = ["endpoint": endpoint,
                    "direction": direction, "interfaces": path.availableInterfaces.map(\.name).joined(separator: ","),
                    "status": String(describing: path.status), "peerToPeerEnabled": "true",
                    "infrastructureAssociation": "unknown"]
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, generation == attempt else { return }
                if case .cancelled = state { observedPaths.removeValue(forKey: id) }
                if case .failed = state { observedPaths.removeValue(forKey: id) }
            }
        }
    }
    func pauseBrowsing() {
        guard mode == .browsing else { return }
        mode = .off; browser?.cancel(); browser = nil
        probes.values.forEach { $0.cancel() }; probes.removeAll()
        endpoints.keys.forEach { onLost?($0) }; endpoints.removeAll(); records.removeAll()
        // Active guest byte connections and their route observations remain owned
        // by the selected guest bridge, independently of background discovery.
    }
    func stop() {
        generation &+= 1; mode = .off
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        probes.values.forEach { $0.cancel() }; probes.removeAll()
        endpoints.keys.forEach { onLost?($0) }; endpoints.removeAll(); records.removeAll()
        bridge.stop()
        observedPaths.removeAll()
        onState?("stopped")
    }
}
