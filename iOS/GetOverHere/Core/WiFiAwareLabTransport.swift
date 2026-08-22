import Foundation
import Network
import Observation
import OSLog
import WiFiAware

let wiFiAwareLabServiceName = "_goh-probe._udp"

@available(iOS 26.4, *)
extension WAPublishableService {
    static var getOverHereProbe: WAPublishableService {
        guard let service = allServices[wiFiAwareLabServiceName] else {
            preconditionFailure("Missing publishable Wi-Fi Aware service declaration")
        }
        return service
    }
}

@available(iOS 26.4, *)
extension WASubscribableService {
    static var getOverHereProbe: WASubscribableService {
        guard let service = allServices[wiFiAwareLabServiceName] else {
            preconditionFailure("Missing subscribable Wi-Fi Aware service declaration")
        }
        return service
    }
}

@MainActor
@Observable
@available(iOS 26.4, *)
final class WiFiAwareLabTransport {
    enum Role: String, CaseIterable, Identifiable {
        case publisher
        case subscriber

        var id: Self { self }
    }

    enum State: String {
        case idle
        case starting
        case advertising
        case browsing
        case connected
        case failed
    }

    struct Capabilities {
        let supported: Bool
        let maximumConnections: Int
        let maximumPublishableServices: Int
        let maximumSubscribableServices: Int
    }

    private typealias ProbeConnection = NetworkConnection<UDP>
    private static let logger = Logger(subsystem: "com.aens.GetOverHere", category: "WiFiAwareLab")
    private static let payloadSize = 45
    private static let probeInterval = Duration.milliseconds(20)

    let capabilities = Capabilities(
        supported: WACapabilities.supportedFeatures.contains(.wifiAware),
        maximumConnections: WACapabilities.maximumConnectableDevices,
        maximumPublishableServices: WACapabilities.maximumPublishableServices,
        maximumSubscribableServices: WACapabilities.maximumSubscribableServices
    )

    var role: Role = .publisher
    var state: State = .idle
    var pairedDeviceCount = 0
    var connectedPeerCount = 0
    var sentFrameCount: UInt64 = 0
    var receivedFrameCount: UInt64 = 0
    var missingFrameCount: UInt64 = 0
    var malformedFrameCount: UInt64 = 0
    var p95RoundTripMilliseconds: Double = 0
    var lastError: String?
    var events: [String] = []
    var isProbing = false

    private var transportTask: Task<Void, Never>?
    private var pairedDevicesTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var connectionTasks: [String: Task<Void, Never>] = [:]
    private var connections: [String: ProbeConnection] = [:]
    private var lastReceivedSequence: [String: UInt64] = [:]
    private var roundTripSamples: [Double] = []
    private var nextSequence: UInt64 = 1

    init() {
        monitorPairedDevices()
    }

    isolated deinit {
        transportTask?.cancel()
        pairedDevicesTask?.cancel()
        probeTask?.cancel()
        connectionTasks.values.forEach { $0.cancel() }
    }

    func start() {
        stop()
        guard capabilities.supported else {
            fail("Wi-Fi Aware is unavailable on this device")
            return
        }

        state = .starting
        lastError = nil
        appendEvent("Starting as \(role.rawValue)")
        transportTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch role {
                case .publisher:
                    try await runPublisher()
                case .subscriber:
                    try await runSubscriber()
                }
            } catch is CancellationError {
                appendEvent("Transport stopped")
            } catch {
                fail("Transport failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        transportTask?.cancel()
        transportTask = nil
        probeTask?.cancel()
        probeTask = nil
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
        connections.removeAll()
        lastReceivedSequence.removeAll()
        connectedPeerCount = 0
        isProbing = false
        if state != .failed {
            state = .idle
        }
    }

    func toggleProbe() {
        if isProbing {
            probeTask?.cancel()
            probeTask = nil
            isProbing = false
            appendEvent("Probe stopped")
            return
        }

        guard !connections.isEmpty else {
            fail("No connected peer for probe")
            return
        }

        isProbing = true
        appendEvent("20 ms probe started, \(Self.payloadSize)-byte payload")
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    await sendProbeToAll()
                    try await Task.sleep(for: Self.probeInterval)
                }
            } catch is CancellationError {
                return
            } catch {
                fail("Probe failed: \(error.localizedDescription)")
            }
        }
    }

    func resetMetrics() {
        sentFrameCount = 0
        receivedFrameCount = 0
        missingFrameCount = 0
        malformedFrameCount = 0
        p95RoundTripMilliseconds = 0
        roundTripSamples.removeAll(keepingCapacity: true)
        lastReceivedSequence.removeAll(keepingCapacity: true)
        appendEvent("Metrics reset")
    }

    private func runPublisher() async throws {
        let listener = try NetworkListener(
            for: .wifiAware(
                .connecting(
                    to: .getOverHereProbe,
                    from: .allPairedDevices,
                    datapath: .realtime
                )
            ),
            using: .parameters { UDP() }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
        )
        .onStateUpdate { [weak self] _, state in
            guard let self else { return }
            switch state {
            case .ready:
                self.state = self.connections.isEmpty ? .advertising : .connected
                self.appendEvent("Publisher ready")
            case .waiting(let error):
                self.appendEvent("Publisher waiting: \(error)")
            case .failed(let error):
                self.fail("Publisher failed: \(error)")
            case .cancelled:
                self.appendEvent("Publisher cancelled")
            case .setup:
                break
            @unknown default:
                self.appendEvent("Publisher entered an unknown state")
            }
        }

        state = .advertising
        try await listener.run { [weak self] connection in
            guard let self else { return }
            self.add(connection)
        }
    }

    private func runSubscriber() async throws {
        state = .browsing
        let browser = NetworkBrowser(
            for: .wifiAware(
                .connecting(to: .allPairedDevices, from: .getOverHereProbe)
            )
        )
        .onStateUpdate { [weak self] _, state in
            guard let self else { return }
            switch state {
            case .ready:
                self.state = .browsing
                self.appendEvent("Subscriber browser ready")
            case .waiting(let error):
                self.appendEvent("Subscriber waiting: \(error)")
            case .failed(let error):
                self.fail("Subscriber failed: \(error)")
            case .cancelled:
                self.appendEvent("Subscriber cancelled")
            case .setup:
                break
            @unknown default:
                self.appendEvent("Subscriber entered an unknown state")
            }
        }

        let endpoint = try await browser.run { endpoints in
            if let endpoint = endpoints.first {
                return .finish(endpoint)
            }
            return .continue
        }
        appendEvent("Discovered publisher")

        let connection = NetworkConnection(
            to: endpoint,
            using: .parameters { UDP() }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
        )
        add(connection)
        try await waitUntilCancelled()
    }

    private func add(_ connection: ProbeConnection) {
        let id = connection.id
        guard connections[id] == nil else { return }
        connections[id] = connection
        connectedPeerCount = connections.count
        state = .connected
        appendEvent("Connection added: \(id)")

        connection.onStateUpdate { [weak self] connection, state in
            guard let self else { return }
            switch state {
            case .ready:
                self.appendEvent("Connection ready: \(connection.id)")
            case .waiting(let error):
                self.appendEvent("Connection waiting: \(error)")
            case .failed(let error):
                self.fail("Connection failed: \(error)")
                self.removeConnection(id: connection.id)
            case .cancelled:
                self.removeConnection(id: connection.id)
            case .setup, .preparing:
                break
            @unknown default:
                self.appendEvent("Connection entered an unknown state")
            }
        }

        connectionTasks[id] = Task { [weak self, connection] in
            guard let self else { return }
            do {
                try await self.receiveLoop(on: connection)
            } catch is CancellationError {
                return
            } catch {
                self.fail("Receive failed: \(error.localizedDescription)")
                self.removeConnection(id: id)
            }
        }
    }

    private func receiveLoop(on connection: ProbeConnection) async throws {
        while !Task.isCancelled {
            let message = try await connection.receive()
            do {
                let frame = try WiFiAwareProbeFrame.decode(message.content)
                receivedFrameCount += 1
                switch frame.kind {
                case .hello:
                    appendEvent("Hello received from \(connection.id)")
                case .probe:
                    recordSequence(frame.sequence, connectionID: connection.id)
                    let echo = WiFiAwareProbeFrame(
                        kind: .echo,
                        sequence: frame.sequence,
                        sentAtNanoseconds: frame.sentAtNanoseconds,
                        payload: frame.payload
                    )
                    try await connection.send(echo.encoded())
                    sentFrameCount += 1
                case .echo:
                    recordRoundTrip(sentAtNanoseconds: frame.sentAtNanoseconds)
                }
            } catch {
                malformedFrameCount += 1
                Self.logger.error(
                    "Malformed probe frame (\(String(describing: type(of: error)), privacy: .public))"
                )
            }
        }
    }

    private func sendProbeToAll() async {
        let payload = Data(repeating: UInt8(truncatingIfNeeded: nextSequence), count: Self.payloadSize)
        let frame = WiFiAwareProbeFrame(
            kind: .probe,
            sequence: nextSequence,
            sentAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            payload: payload
        )
        nextSequence &+= 1

        for connection in connections.values {
            do {
                try await connection.send(frame.encoded())
                sentFrameCount += 1
            } catch {
                fail("Send failed on \(connection.id): \(error.localizedDescription)")
            }
        }
    }

    private func recordSequence(_ sequence: UInt64, connectionID: String) {
        if let previous = lastReceivedSequence[connectionID], sequence > previous + 1 {
            missingFrameCount += sequence - previous - 1
        }
        lastReceivedSequence[connectionID] = max(lastReceivedSequence[connectionID] ?? 0, sequence)
    }

    private func recordRoundTrip(sentAtNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= sentAtNanoseconds else { return }
        roundTripSamples.append(Double(now - sentAtNanoseconds) / 1_000_000)
        if roundTripSamples.count > 1_000 {
            roundTripSamples.removeFirst(roundTripSamples.count - 1_000)
        }
        let sorted = roundTripSamples.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        p95RoundTripMilliseconds = sorted[index]
    }

    private func removeConnection(id: String) {
        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)?.cancel()
        lastReceivedSequence.removeValue(forKey: id)
        connectedPeerCount = connections.count
        if connections.isEmpty, state == .connected {
            state = role == .publisher ? .advertising : .browsing
        }
        appendEvent("Connection removed: \(id)")
    }

    private func monitorPairedDevices() {
        pairedDevicesTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await devices in WAPairedDevice.allDevices {
                    pairedDeviceCount = devices.count
                }
            } catch is CancellationError {
                return
            } catch {
                fail("Paired-device monitor failed: \(error.localizedDescription)")
            }
        }
    }

    private func waitUntilCancelled() async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        throw CancellationError()
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed
        appendEvent(message)
        Self.logger.error("\(message, privacy: .private)")
    }

    private func appendEvent(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        events.insert("\(timestamp)  \(message)", at: 0)
        if events.count > 80 {
            events.removeLast(events.count - 80)
        }
        Self.logger.info("\(message, privacy: .private)")
    }
}
