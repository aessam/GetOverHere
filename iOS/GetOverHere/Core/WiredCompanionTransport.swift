import CryptoKit
import Foundation
import LocalLinkSecurity
import Network
import os
import TourSessionCore

@MainActor
protocol WiredCompanionTransport: GuideLaneConnector {
    var onDescriptor: ((GatewayRoomDescriptor?) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func stop()
}

/// Public NWPath classification selects the wired interface. Names and observed
/// addresses are never hardcoded; a Wi-Fi route cannot satisfy this selection.
@MainActor @Observable
final class WiredInterfaceMonitor {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private(set) var interfaces: [NWInterface] = []
    var selectedName = ""
    var selected: NWInterface? { interfaces.first { $0.name == selectedName } ?? (interfaces.count == 1 ? interfaces.first : nil) }
    var addresses: [String] { selected.map { Self.addresses(on: $0.name) } ?? [] }
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.interfaces = path.availableInterfaces.filter { $0.type == .wiredEthernet } }
        }
        monitor.start(queue: .main)
    }
    deinit { monitor.cancel() }

    nonisolated static func addresses(on name: String) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var entry = head; var values: [String] = []
        while let node = entry {
            defer { entry = node.pointee.ifa_next }
            guard String(cString: node.pointee.ifa_name) == name, let address = node.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.append(String(cString: host))
            }
        }
        return values.sorted { !$0.contains(":") && $1.contains(":") }
    }

    /// QR endpoints cannot name a DNS host, own address, or off-link destination.
    nonisolated static func peerHost(_ host: String, on name: String) throws -> String {
        let bare = String(host.split(separator: "%", omittingEmptySubsequences: false).first ?? "")
        var peer4 = in_addr(); var peer6 = in6_addr()
        let family: Int32
        if inet_pton(AF_INET, bare, &peer4) == 1 { family = AF_INET }
        else if inet_pton(AF_INET6, bare, &peer6) == 1 { family = AF_INET6 }
        else { throw GatewayProtocolError.malformed }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw NearbyConnectionError.unavailable }
        defer { freeifaddrs(head) }
        var entry = head
        while let node = entry {
            defer { entry = node.pointee.ifa_next }
            guard String(cString: node.pointee.ifa_name) == name, let address = node.pointee.ifa_addr,
                  let mask = node.pointee.ifa_netmask, Int32(address.pointee.sa_family) == family else { continue }
            if family == AF_INET {
                let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                guard peer4.s_addr != local, netmask != 0, (peer4.s_addr & netmask) == (local & netmask) else { continue }
                return bare
            }
            var local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            var netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let peerBytes = withUnsafeBytes(of: &peer6) { Array($0) }
            let localBytes = withUnsafeBytes(of: &local) { Array($0) }
            let masks = withUnsafeBytes(of: &netmask) { Array($0) }
            guard peerBytes != localBytes, masks.contains(where: { $0 != 0 }),
                  zip(zip(peerBytes, localBytes), masks).allSatisfy({ ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }) else { continue }
            return peerBytes[0] == 0xfe && peerBytes[1] & 0xc0 == 0x80 ? "\(bare)%\(name)" : bare
        }
        throw NearbyConnectionError.unavailable
    }
}

@MainActor
final class LiveWiredCompanionTransport: WiredCompanionTransport {
    var onDescriptor: ((GatewayRoomDescriptor?) -> Void)?
    var onError: ((String) -> Void)?
    var onState: ((String) -> Void)?
    private(set) var routeInterface = ""
    private(set) var descriptor: GatewayRoomDescriptor?
    private(set) var connectionCount = 0
    private(set) var observedWiredInterface: String?
    var peerCertificateSHA256: String? { peerPin?.map { String(format: "%02x", $0) }.joined() }
    private var retiredReceived: UInt64 = 0
    private var retiredSent: UInt64 = 0
    private var metricsPairingID: UUID?
    var byteCounts: (received: UInt64, sent: UInt64) {
        connections.values.compactMap { $0 as? NearbyTCPConnection }.reduce((retiredReceived, retiredSent)) {
            ($0.0 + $1.bytesRead, $0.1 + $1.bytesWritten)
        }
    }
    private var listener: NWListener?
    private var connections: [UUID: any NearbyByteConnection] = [:]
    private var openingConnections: [UUID: NearbyTCPConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var controlID: UUID?
    private var attempt: UInt64 = 0
    private var generation: UInt64 = 0
    private var admissionIDs = Set<UUID>()
    private var pendingIDs = Set<UUID>()
    private var offer: GatewayPairingMessage?
    private var identity: LocalLinkIdentity?
    private var peerPin: Data?
    private var interface: NWInterface?
    private var getHosted: (() -> (BluetoothRoomRecord, Data)?)?
    private var requiredInterfaceType = NWInterface.InterfaceType.wiredEthernet
    private let localConnect: @MainActor (UInt16) -> any NearbyByteConnection
    private let discovery: any WiredHubDiscovering
    private var remoteEndpoint: NWEndpoint?
    private var associationConfirmed = false
    #if DEBUG
    /// Deterministic cancellation boundary; not reachable from UI/debug commands.
    var descriptorDecodedForComponentTest: (() -> Void)?
    #endif

    init(localConnect: @escaping @MainActor (UInt16) -> any NearbyByteConnection = { NearbyTCPConnection(port: $0) },
         discovery: (any WiredHubDiscovering)? = nil) {
        self.localConnect = localConnect
        self.discovery = discovery ?? WiredHubDiscovery()
    }
    #if DEBUG
    /// Explicit component-test seam. No UI/debug command can select it; release
    /// builds contain only wiredEthernet routing and on-link endpoint validation.
    convenience init(loopbackComponentTest: Void, localConnect: @escaping @MainActor (UInt16) -> any NearbyByteConnection = { NearbyTCPConnection(port: $0) },
                     discovery: (any WiredHubDiscovering)? = nil) {
        self.init(localConnect: localConnect, discovery: discovery); requiredInterfaceType = .loopback
    }
    #endif

    func startGuide(identity: LocalLinkIdentity, offer: GatewayPairingMessage,
                    response: GatewayPairingMessage, interface: NWInterface,
                    hosted: @escaping () -> (BluetoothRoomRecord, Data)?) throws {
        try response.validateResponse(to: offer, nowMilliseconds: Self.wallMilliseconds)
        guard interface.type == requiredInterfaceType else { throw NearbyConnectionError.unavailable }
        stop()
        prepareMetrics(offer.pairingID)
        self.identity = identity; self.offer = offer; peerPin = response.certificateFingerprint
        self.interface = interface; routeInterface = interface.name; getHosted = hosted
        try listenGuide(on: interface)
    }

    /// Rebind only socket/interface state. Enrollment and guide authority are unchanged.
    func resumeGuide(on interface: NWInterface) throws {
        guard let offer, getHosted != nil, self.identity != nil, peerPin != nil else { throw GatewayProtocolError.unconfirmed }
        if !associationConfirmed { try offer.validate(nowMilliseconds: Self.wallMilliseconds) }
        guard interface.type == requiredInterfaceType else { throw NearbyConnectionError.unavailable }
        suspend()
        self.interface = interface; routeInterface = interface.name
        try listenGuide(on: interface)
    }

    private func listenGuide(on interface: NWInterface) throws {
        guard let identity, let offer, let peerPin else { throw GatewayProtocolError.unconfirmed }
        let parameters = try Self.parameters(identity, pin: peerPin, interface: interface)
        // Bind the selected interface, not the address captured in the enrollment QR.
        // A replaced cable may assign a different address to this same confirmed peer.
        let listener = try NWListener(using: parameters, on: .init(rawValue: offer.port)!)
        var service = NWListener.Service(name: WiredHubDiscovery.instanceName(offer.pairingID), type: WiredHubDiscovery.serviceType)
        service.noAutoRename = true
        listener.service = service
        let token = attempt
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == token else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == token else { return }
                if case .ready = state { self.onState?("waiting-for-companion") }
                if case .failed(let error) = state { self.fail(error) }
            }
        }
        self.listener = listener; listener.start(queue: .main)
    }

    func startCompanion(identity: LocalLinkIdentity, offer: GatewayPairingMessage, interface: NWInterface,
                        confirmedAssociation: Bool = false) throws {
        if !confirmedAssociation { try offer.validateReceivedOffer(nowMilliseconds: Self.wallMilliseconds) }
        guard offer.role == .offer else { throw GatewayProtocolError.mismatchedPairing }
        guard interface.type == requiredInterfaceType else { throw NearbyConnectionError.unavailable }
        stop()
        prepareMetrics(offer.pairingID)
        self.identity = identity; self.offer = offer; peerPin = offer.certificateFingerprint
        self.interface = interface; routeInterface = interface.name
        associationConfirmed = confirmedAssociation
        let id = UUID(); let token = attempt
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                if confirmedAssociation || requiredInterfaceType == .wiredEthernet {
                    remoteEndpoint = try await discovery.endpoint(pairingID: offer.pairingID, interface: interface)
                    guard attempt == token, !Task.isCancelled else { throw CancellationError() }
                }
                let connection = try await openConnection()
                guard attempt == token, !Task.isCancelled else { connection.close(); throw CancellationError() }
                own(connection, id: id); controlID = id
                let handshakeDeadline = Self.deadline(connection, milliseconds: 5_000)
                defer { handshakeDeadline.cancel() }
                try await connection.write(try GatewayLaneRequest(pairingID: offer.pairingID, roomID: offer.roomID,
                    generation: 0, lane: .hubControl).encode())
                try await Self.accepted(connection)
                handshakeDeadline.cancel()
                guard attempt == token, controlID == id, !Task.isCancelled else { throw CancellationError() }
                try verifyWiredPath(connection.currentPath)
                while !Task.isCancelled, attempt == token {
                    let deadline = Self.deadline(connection, milliseconds: GatewayProtocol.heartbeatTimeoutMilliseconds)
                    let value: GatewayRoomDescriptor
                    do { value = try await Self.readDescriptor(connection); deadline.cancel() }
                    catch { deadline.cancel(); throw error }
                    #if DEBUG
                    descriptorDecodedForComponentTest?()
                    #endif
                    guard attempt == token, controlID == id, !Task.isCancelled else { throw CancellationError() }
                    guard value.record.roomID == offer.roomID, value.record.guideID == offer.guideID,
                          Data(SHA256.hash(data: value.guidePublicKey)) == offer.guideKeyFingerprint else {
                        throw GatewayProtocolError.mismatchedPairing
                    }
                    if let old = descriptor {
                        guard old.generation == value.generation, old.recordRevision <= value.recordRevision,
                              old.recordRevision != value.recordRevision || old == value else {
                            throw GatewayProtocolError.wrongGeneration
                        }
                    }
                    associationConfirmed = true
                    descriptor = value; onDescriptor?(value); onState?("forwarding")
                    let ackDeadline = Self.deadline(connection, milliseconds: GatewayProtocol.heartbeatTimeoutMilliseconds)
                    do {
                        try await connection.write(Data([GatewayProtocol.descriptorAcknowledgement])); ackDeadline.cancel()
                    } catch { ackDeadline.cancel(); throw error }
                }
            } catch { if attempt == token, !Task.isCancelled { fail(error) } }
        }
    }

    func connect(lane: NearbyLaneRequest.Lane, roomID: UUID) async throws -> any NearbyByteConnection {
        guard let offer, let descriptor, descriptor.record.roomID == roomID, controlID != nil else {
            throw NearbyConnectionError.unavailable
        }
        guard connections.count < 96 else { throw GatewayProtocolError.capacity }
        let id = UUID(); let token = attempt
        let connection = try await openConnection()
        guard attempt == token, self.descriptor?.generation == descriptor.generation else { connection.close(); throw GatewayProtocolError.wrongGeneration }
        own(connection, id: id)
        let deadline = Self.deadline(connection, milliseconds: 5_000)
        defer { deadline.cancel() }
        do {
            try await connection.write(try GatewayLaneRequest(pairingID: offer.pairingID, roomID: roomID,
                generation: descriptor.generation, lane: .init(lane)).encode())
            try await Self.accepted(connection)
            try verifyWiredPath(connection.currentPath)
            guard attempt == token, self.descriptor?.generation == descriptor.generation else {
                throw GatewayProtocolError.wrongGeneration
            }
            return GatewayOwnedConnection(connection) { [weak self] in self?.release(id) }
        } catch { release(id); throw error }
    }

    private func openConnection() async throws -> NearbyTCPConnection {
        guard let identity, let offer, let peerPin, let interface else { throw NearbyConnectionError.closed }
        guard connections.count + openingConnections.count < 96 else { throw GatewayProtocolError.capacity }
        let endpoint: NWEndpoint
        if let remoteEndpoint { endpoint = remoteEndpoint }
        else {
        let host: String
        #if DEBUG
        if requiredInterfaceType == .loopback {
            guard offer.host.hasPrefix("127.") else { throw GatewayProtocolError.malformed }
            host = offer.host
        } else { host = try WiredInterfaceMonitor.peerHost(offer.host, on: interface.name) }
        #else
        host = try WiredInterfaceMonitor.peerHost(offer.host, on: interface.name)
        #endif
        endpoint = .hostPort(host: .init(host), port: .init(rawValue: offer.port)!)
        }
        let connection = NWConnection(to: endpoint, using: try Self.parameters(identity, pin: peerPin, interface: interface))
        let readiness = WiredConnectionReadiness()
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: readiness.finish(.success(()))
                case .failed(let error), .waiting(let error): readiness.finish(.failure(error))
                case .cancelled: readiness.finish(.failure(NearbyConnectionError.closed))
                default: break
                }
            }
        }
        let stream = NearbyTCPConnection(connection)
        let openingID = UUID()
        openingConnections[openingID] = stream
        connectionCount = connections.count + openingConnections.count
        let deadline = Self.deadline(stream, milliseconds: 5_000)
        defer {
            deadline.cancel(); openingConnections.removeValue(forKey: openingID)
            connectionCount = connections.count + openingConnections.count
        }
        do {
            try await withTaskCancellationHandler { try await readiness.wait() }
                onCancel: { Task { @MainActor in stream.close() } }
            try Task.checkCancellation()
            try verifyWiredPath(connection.currentPath)
            return stream
        } catch { stream.close(); throw error }
    }

    private static func parameters(_ identity: LocalLinkIdentity, pin: Data, interface: NWInterface) throws -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 5
        let value = NWParameters(tls: try identity.tlsOptions(expectedPeerPin: pin), tcp: tcp)
        value.requiredInterface = interface
        value.allowLocalEndpointReuse = true
        return value
    }

    private func accept(_ native: NWConnection) {
        guard connections.count < 100, pendingIDs.count < 8 else { native.cancel(); return }
        let id = UUID(); let token = attempt
        let remote = NearbyTCPConnection(native); own(remote, id: id)
        pendingIDs.insert(id)
        tasks[id] = Task { [weak self] in
            guard let self else { remote.close(); return }
            let deadline = Self.deadline(remote, milliseconds: 5_000)
            defer { deadline.cancel(); release(id) }
            var accepted = false
            do {
                let request = try GatewayLaneRequest.decode(try await remote.readExactly(GatewayLaneRequest.size))
                try verifyWiredPath(native.currentPath)
                pendingIDs.remove(id)
                guard token == attempt, let offer, request.pairingID == offer.pairingID,
                      request.roomID == offer.roomID, let hosted = getHosted?(), hosted.0.roomID == offer.roomID,
                      hosted.0.guideID == offer.guideID, Data(SHA256.hash(data: hosted.1)) == offer.guideKeyFingerprint else {
                    throw GatewayProtocolError.mismatchedPairing
                }
                if request.lane == .hubControl {
                    guard controlID == nil else { throw GatewayProtocolError.capacity }
                    associationConfirmed = true
                    generation &+= 1; controlID = id
                    try await remote.write(Data([GatewayLaneRequest.Reply.accepted.rawValue])); accepted = true; deadline.cancel()
                    try await sendDescriptors(remote, id: id, token: token)
                } else {
                    guard controlID != nil, request.generation == generation, let port = request.lane.localPort else {
                        throw GatewayProtocolError.wrongGeneration
                    }
                    if request.lane == .admission {
                        guard admissionIDs.count < GatewayProtocol.forwardedAdmissionLimit else { throw GatewayProtocolError.capacity }
                        admissionIDs.insert(id)
                    }
                    let local = localConnect(port)
                    defer { local.close() }
                    try await remote.write(Data([GatewayLaneRequest.Reply.accepted.rawValue])); accepted = true; deadline.cancel()
                    try await NearbySocketBridge.pump(remote, local, realtime: request.lane == .realtime,
                        drainAdmissionReply: request.lane == .admission,
                        audioResidenceMilliseconds: GatewayProtocol.audioResidenceMilliseconds,
                        reliableWriteTimeoutMilliseconds: 5_000)
                }
            } catch {
                if token == attempt, !Task.isCancelled {
                    if !accepted {
                        do { try await remote.write(Data([error as? GatewayProtocolError == .capacity ? 2 : 1])) }
                        catch { Logger.transport.debug("Wired rejection reply could not be delivered") }
                    }
                    Logger.transport.error("Wired lane rejected or closed: \(String(describing: type(of: error)))")
                    if controlID == id { onError?(error.localizedDescription) }
                }
            }
        }
    }

    private func sendDescriptors(_ remote: any NearbyByteConnection, id: UUID, token: UInt64) async throws {
        guard !Task.isCancelled, attempt == token, controlID == id else { throw CancellationError() }
        var revision: UInt64 = 0; var old: BluetoothRoomRecord?
        onState?("companion-connected")
        while !Task.isCancelled, attempt == token, controlID == id {
            guard let hosted = getHosted?(), hosted.0.roomID == offer?.roomID else { throw GatewayProtocolError.revoked }
            if old != hosted.0 { revision &+= 1; old = hosted.0 }
            let value = try GatewayRoomDescriptor(generation: generation, recordRevision: revision,
                record: hosted.0, guidePublicKey: hosted.1)
            descriptor = value
            let bytes = try value.encode()
            let deadline = Self.deadline(remote, milliseconds: GatewayProtocol.heartbeatTimeoutMilliseconds)
            do {
                try await remote.write(Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes)
                guard try await remote.readExactly(1) == Data([GatewayProtocol.descriptorAcknowledgement]) else { throw GatewayProtocolError.malformed }
                deadline.cancel()
            }
            catch { deadline.cancel(); throw error }
            try await Task.sleep(for: .milliseconds(GatewayProtocol.heartbeatMilliseconds))
        }
    }

    private static func accepted(_ connection: any NearbyByteConnection) async throws {
        guard try await connection.readExactly(1) == Data([0]) else { throw NearbyConnectionError.rejected }
    }
    private func verifyWiredPath(_ path: NWPath?) throws {
        guard let path, path.status == .satisfied, path.usesInterfaceType(requiredInterfaceType),
              let interface, path.availableInterfaces.contains(where: { $0.name == interface.name && $0.type == requiredInterfaceType }) else {
            throw NearbyConnectionError.unavailable
        }
        observedWiredInterface = interface.name
        if getHosted == nil {
            guard case let .hostPort(_, port) = path.remoteEndpoint,
                  port.rawValue == GatewayProtocol.servicePort else { throw GatewayProtocolError.malformed }
        }
        if requiredInterfaceType == .wiredEthernet {
            guard case let .hostPort(host, _) = path.remoteEndpoint else { throw NearbyConnectionError.unavailable }
            _ = try WiredInterfaceMonitor.peerHost(String(describing: host), on: interface.name)
        }
    }
    private static func readDescriptor(_ connection: any NearbyByteConnection) async throws -> GatewayRoomDescriptor {
        let count = try await connection.readExactly(2).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...GatewayProtocol.maximumControlFrameSize).contains(count) else { throw GatewayProtocolError.malformed }
        return try GatewayRoomDescriptor.decode(try await connection.readExactly(count))
    }
    private static func deadline(_ connection: any NearbyByteConnection, milliseconds: UInt64) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .milliseconds(milliseconds)); connection.close() }
            catch is CancellationError { return }
            catch { Logger.transport.error("Wired deadline failed (\(String(describing: type(of: error))), code=\((error as NSError).code))") }
        }
    }
    private func own(_ connection: any NearbyByteConnection, id: UUID) {
        connections[id] = connection; connectionCount = connections.count + openingConnections.count
    }
    private func release(_ id: UUID) {
        if let connection = connections.removeValue(forKey: id) {
            retainMetrics(connection); connection.close()
        }
        tasks.removeValue(forKey: id); admissionIDs.remove(id); pendingIDs.remove(id)
        if controlID == id {
            controlID = nil; descriptor = nil; onDescriptor?(nil)
            let other = Array(connections.keys); other.forEach { release($0) }
            onState?("wired-disconnected")
        }
        connectionCount = connections.count + openingConnections.count
    }
    private func fail(_ error: any Error) { suspend(); onError?("Wired companion: \(error.localizedDescription)") }
    private func prepareMetrics(_ pairing: UUID) {
        if metricsPairingID != pairing { retiredReceived = 0; retiredSent = 0; metricsPairingID = pairing }
    }
    private func retainMetrics(_ connection: any NearbyByteConnection) {
        if let connection = connection as? NearbyTCPConnection {
            retiredReceived &+= connection.bytesRead; retiredSent &+= connection.bytesWritten
        }
    }
    /// Cable loss is not revocation. Keep identity and original enrollment immutable.
    func suspend() {
        attempt &+= 1; listener?.cancel(); listener = nil
        discovery.stop(); remoteEndpoint = nil
        openingConnections.values.forEach { $0.close() }; openingConnections.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        connections.values.forEach { retainMetrics($0); $0.close() }; connections.removeAll(); admissionIDs.removeAll(); pendingIDs.removeAll()
        controlID = nil; descriptor = nil; connectionCount = 0
        observedWiredInterface = nil
        onDescriptor?(nil); onState?("wired-disconnected")
    }
    func stop() {
        suspend()
        getHosted = nil; associationConfirmed = false
        identity = nil; offer = nil; peerPin = nil; interface = nil
        onState?("stopped")
    }
    static var wallMilliseconds: UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000) }
}

@MainActor
private final class WiredConnectionReadiness {
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Void, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
}

@MainActor
private final class GatewayOwnedConnection: NearbyByteConnection {
    private let base: any NearbyByteConnection
    private var didClose: (() -> Void)?
    init(_ base: any NearbyByteConnection, onClose: @escaping () -> Void) { self.base = base; didClose = onClose }
    func read(maximum: Int) async throws -> Data { try await base.read(maximum: maximum) }
    func write(_ bytes: Data) async throws { try await base.write(bytes) }
    func close() { base.close(); let callback = didClose; didClose = nil; callback?() }
}
