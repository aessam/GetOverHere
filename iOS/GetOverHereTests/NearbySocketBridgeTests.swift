import Foundation
import Network
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite(.serialized)
@MainActor
struct NearbySocketBridgeTests {
    @Test func strictApplePeerCannotSubstituteBluetoothOrAware() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Room", isAndroid: false, isLocked: false, admissionVersion: 2)
        let bluetooth = RouteBluetoothTestRadio(record: record)
        let aware = RouteAwareTestRadio(); aware.record = record
        let plane = LocalControlPlane(displayName: "Guest", bluetooth: bluetooth, makeAware: { aware })
        defer { plane.stop() }
        plane.setAwareDiscoveryMode(.browsing); aware.onRoom?(record)
        plane.strictApplePeer = true
        #expect(!plane.canConnectNearby(roomID: record.roomID))
        await #expect(throws: NearbyConnectionError.self) {
            try await plane.prepareNearbyGuest(roomID: record.roomID, expectedGuideID: record.guideID)
        }
        #expect(bluetooth.connectCalls == 0)
    }
    @Test func companionConnectorPreservesEachLeafAndNeverOpensLocalGuide() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Original Android Guide",
            isAndroid: true, isLocked: false, admissionVersion: 2)
        let connector = GatewayTestConnector()
        var localOpened = false
        let bridge = NearbySocketBridge(budget: NearbyConnectionBudget(), localConnect: { _ in
            localOpened = true
            return BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true)
        })
        bridge.guideConnector = connector
        defer { bridge.stop() }
        var leaves: [BufferedNearbyTestConnection] = []
        for _ in 0..<2 {
            let leaf = BufferedNearbyTestConnection(bytes: try NearbyLaneRequest(lane: .control, roomID: record.roomID).encode(), waitsForClose: true)
            leaves.append(leaf); bridge.accept(leaf) { record }
        }
        for _ in 0..<200 { await Task.yield() }
        #expect(!localOpened)
        #expect(connector.requests.count == 2)
        #expect(connector.requests.allSatisfy { $0.0 == .control && $0.1 == record.roomID })
        #expect(connector.connections.count == 2)
        #expect(connector.connections[0] !== connector.connections[1])
        #expect(leaves.allSatisfy { $0.pendingOutput == Data([0]) })
        bridge.stop()
        #expect(connector.connections.allSatisfy { $0.closed })
    }

    @Test func metadataDoesNotOpenAnyWiredApplicationLane() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Forwarded", isAndroid: true, isLocked: true)
        let connector = GatewayTestConnector()
        let bridge = NearbySocketBridge(budget: NearbyConnectionBudget()); bridge.guideConnector = connector
        defer { bridge.stop() }
        let listener = try TestNearbyListener(bridge: bridge, record: record)
        defer { listener.close() }
        let port = try await listener.start()
        #expect(try await NearbySocketBridge.readRecord { NearbyTCPConnection(port: port) } == record)
        #expect(connector.requests.isEmpty)
    }
    @Test("Thirty three-lane leases and eight transient leases share one app budget")
    func softwareBudgetIsSharedAndLaneBounded() throws {
        let budget = NearbyConnectionBudget()
        var persistent: [UUID] = []
        for lane in [NearbyLaneRequest.Lane.realtime, .control, .asset] {
            for _ in 0..<SessionCapacityPolicy.listenerLimit {
                let lease = try budget.acquireBootstrap()
                try budget.promote(lease, lane: lane)
                persistent.append(lease)
            }
            let overflow = try budget.acquireBootstrap()
            #expect(throws: NearbyConnectionError.self) { try budget.promote(overflow, lane: lane) }
            budget.release(overflow)
        }
        let bootstrap = try (0..<8).map { _ in try budget.acquireBootstrap() }
        #expect(budget.connectionCount == SessionCapacityPolicy.maximumBridgeConnections)
        #expect(budget.persistentCount == 90)
        #expect(budget.bootstrapCount == 8)
        #expect(throws: NearbyConnectionError.self) { try budget.acquireBootstrap() }
        persistent.forEach { budget.release($0) }
        persistent.forEach { budget.release($0) }
        #expect(budget.connectionCount == 8)
        bootstrap.forEach { budget.release($0) }
        #expect(budget.connectionCount == 0)
    }

    @Test func stoppingOneBridgeReleasesOnlyItsOwnSharedLeases() async throws {
        let budget = NearbyConnectionBudget(persistentLimit: 3, bootstrapLimit: 2, perLaneLimit: 1)
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false)
        let first = NearbySocketBridge(budget: budget, localConnect: { _ in BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true) })
        let second = NearbySocketBridge(budget: budget, localConnect: { _ in BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true) })
        defer { first.stop(); second.stop() }
        let realtime = BufferedNearbyTestConnection(bytes: try NearbyLaneRequest(lane: .realtime, roomID: record.roomID).encode(), waitsForClose: true)
        let control = BufferedNearbyTestConnection(bytes: try NearbyLaneRequest(lane: .control, roomID: record.roomID).encode(), waitsForClose: true)
        first.accept(realtime) { record }
        second.accept(control) { record }
        for _ in 0..<100 { await Task.yield() }
        #expect(budget.persistentCount == 2)
        first.stop(); first.stop()
        for _ in 0..<100 { await Task.yield() }
        #expect(realtime.closed)
        #expect(!control.closed)
        #expect(budget.persistentCount == 1)
        second.stop()
        #expect(budget.connectionCount == 0)
    }

    @Test func bootstrapExhaustionRejectsBeforeLocalOrRemoteConnect() async throws {
        let budget = NearbyConnectionBudget(persistentLimit: 3, bootstrapLimit: 1, perLaneLimit: 1)
        let pending = try budget.acquireBootstrap()
        defer { budget.release(pending) }
        var localOpened = false
        var remoteOpened = false
        let bridge = NearbySocketBridge(budget: budget, localConnect: { _ in
            localOpened = true
            return BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true)
        })
        defer { bridge.stop() }
        let remote = BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true)
        bridge.accept(remote) { nil }
        await #expect(throws: NearbyConnectionError.self) {
            try await NearbySocketBridge.readRecord(budget: budget) {
                remoteOpened = true
                return remote
            }
        }
        #expect(remote.closed)
        #expect(!localOpened && !remoteOpened)
        #expect(budget.connectionCount == 1)
    }

    @Test func cancelledMetadataConnectReleasesItsLeaseAndClosesLateHandle() async throws {
        let budget = NearbyConnectionBudget(persistentLimit: 3, bootstrapLimit: 1, perLaneLimit: 1)
        var pending: CheckedContinuation<any NearbyByteConnection, Never>?
        let probe = Task {
            try await NearbySocketBridge.readRecord(budget: budget) {
                await withCheckedContinuation { pending = $0 }
            }
        }
        for _ in 0..<100 { await Task.yield() }
        let connect = try #require(pending)
        #expect(budget.bootstrapCount == 1)
        probe.cancel()
        for _ in 0..<100 { await Task.yield() }
        #expect(budget.connectionCount == 0)
        let replacement = try budget.acquireBootstrap()
        defer { budget.release(replacement) }
        let late = BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true)
        connect.resume(returning: late)
        await #expect(throws: CancellationError.self) { try await probe.value }
        #expect(late.closed)
        #expect(budget.connectionCount == 1)
    }

    @Test("Native route descriptor retains provenance across adapter preparation", arguments: [false, true])
    func nearbyRouteIdentityIsTypedAndReplacedOnlyOnTeardown(useAware: Bool) async throws {
        let room = UUID()
        let guideID = UUID()
        let record = BluetoothRoomRecord(roomID: room, guideID: guideID, name: "Room", isAndroid: false, isLocked: false, admissionVersion: 2)
        let bluetooth = RouteBluetoothTestRadio(record: record)
        let aware = RouteAwareTestRadio()
        aware.record = record
        let plane = LocalControlPlane(displayName: "Guest", bluetooth: bluetooth,
            guestBridge: NearbySocketBridge(budget: NearbyConnectionBudget(), guestPort: { _ in 0 }),
            makeAware: { aware })
        defer { plane.stop() }
        if useAware {
            plane.setAwareDiscoveryMode(.browsing)
            aware.onRoom?(record)
        }
        let first = try await plane.prepareNearbyGuest(roomID: room, expectedGuideID: guideID)
        #expect(first.adapterHost == "127.0.0.1")
        #expect(first.transport == (useAware ? .wifiAware : .bluetooth))
        #expect(first.roomID == room)
        #expect(try await plane.prepareNearbyGuest(roomID: room, expectedGuideID: guideID) == first)
        await #expect(throws: NearbyConnectionError.self) { try await plane.prepareNearbyGuest(roomID: UUID(), expectedGuideID: guideID) }
        await #expect(throws: RoomAdmissionV2Error.self) { try await plane.prepareNearbyGuest(roomID: room, expectedGuideID: UUID()) }
        #expect(bluetooth.joinedRoom == (useAware ? nil : room))
        plane.stopNearbyGuest()
        #expect(bluetooth.joinedRoom == nil)
        let replacement = try await plane.prepareNearbyGuest(roomID: room, expectedGuideID: guideID)
        #expect(replacement.routeID != first.routeID)
        #expect(replacement.transport == first.transport)
        #expect(bluetooth.connectCalls == (useAware ? 0 : 3))
        #expect(bluetooth.requestedLanes == (useAware ? [] : [.metadata, .metadata, .metadata]))
        #expect(aware.connectCalls == (useAware ? 3 : 0))
    }

    @Test func unavailableAwarePathFallsBackToTheSameBluetoothGuide() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false, admissionVersion: 2)
        let bluetooth = RouteBluetoothTestRadio(record: record)
        let aware = RouteAwareTestRadio()
        aware.connectionError = NearbyConnectionError.unavailable
        let plane = LocalControlPlane(displayName: "Guest", bluetooth: bluetooth,
            guestBridge: NearbySocketBridge(budget: NearbyConnectionBudget(), guestPort: { _ in 0 }), makeAware: { aware })
        var errors: [String] = []
        plane.onNearbyError = { errors.append($0) }
        defer { plane.stop() }
        plane.setAwareDiscoveryMode(.browsing)
        aware.onRoom?(record)
        let route = try await plane.prepareNearbyGuest(roomID: record.roomID, expectedGuideID: record.guideID)
        #expect(route.transport == .bluetooth)
        #expect(aware.connectCalls == 1 && bluetooth.connectCalls == 1)
        #expect(errors.count == 1 && errors[0].contains("Trying Bluetooth"))
    }

    @Test(arguments: ["room", "guide", "version"])
    func nearbyMetadataIdentityFailureIsTerminalWithoutDowngrade(mismatch: String) async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false, admissionVersion: 2)
        let bluetooth = RouteBluetoothTestRadio(record: record)
        let aware = RouteAwareTestRadio()
        aware.record = BluetoothRoomRecord(roomID: mismatch == "room" ? UUID() : record.roomID,
            guideID: mismatch == "guide" ? UUID() : record.guideID, name: "Tour", isAndroid: false,
            isLocked: false, admissionVersion: mismatch == "version" ? 1 : 2)
        let plane = LocalControlPlane(displayName: "Guest", bluetooth: bluetooth,
            guestBridge: NearbySocketBridge(budget: NearbyConnectionBudget(), guestPort: { _ in 0 }), makeAware: { aware })
        defer { plane.stop() }
        plane.setAwareDiscoveryMode(.browsing)
        aware.onRoom?(record)
        await #expect(throws: RoomAdmissionV2Error.self) {
            try await plane.prepareNearbyGuest(roomID: record.roomID, expectedGuideID: record.guideID)
        }
        #expect(aware.connectCalls == 1 && bluetooth.connectCalls == 0)
    }

    @Test("A cached Aware route is probed and replaced by Bluetooth after path loss")
    func cachedAwareFailureRebuildsBluetoothRoute() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false, admissionVersion: 2)
        let bluetooth = RouteBluetoothTestRadio(record: record)
        let aware = RouteAwareTestRadio()
        aware.record = record
        let plane = LocalControlPlane(displayName: "Guest", bluetooth: bluetooth,
            guestBridge: NearbySocketBridge(budget: NearbyConnectionBudget(), guestPort: { _ in 0 }), makeAware: { aware })
        defer { plane.stop() }
        plane.setAwareDiscoveryMode(.browsing)
        aware.onRoom?(record)
        let first = try await plane.prepareNearbyGuest(roomID: record.roomID, expectedGuideID: record.guideID)
        aware.connectionError = NearbyConnectionError.unavailable
        let replacement = try await plane.prepareNearbyGuest(roomID: record.roomID, expectedGuideID: record.guideID)
        #expect(first.transport == .wifiAware && replacement.transport == .bluetooth)
        #expect(first.routeID != replacement.routeID)
        #expect(aware.connectCalls == 3 && bluetooth.connectCalls == 1)
        #expect(bluetooth.joinedRoom == record.roomID)
    }

    @Test("Adapter restart waits for native cancellation before reusing its fixed ports")
    func immediateFixedPortRestartDoesNotRaceListenerTeardown() async throws {
        let bridge = NearbySocketBridge(budget: NearbyConnectionBudget(), guestPort: { 60_009 + UInt16($0.rawValue) })
        defer { bridge.stop() }
        let room = UUID()
        for _ in 0..<5 {
            #expect(try await bridge.startGuest(roomID: room) { throw NearbyConnectionError.unavailable } == "127.0.0.1")
            bridge.stop()
        }
    }

    @Test func adapterPassesEachApplicationLaneToItsNativeConnector() async throws {
        let room = UUID()
        let bridge = NearbySocketBridge(budget: NearbyConnectionBudget(), guestPort: { 60_119 + UInt16($0.rawValue) })
        var requested: [NearbyLaneRequest.Lane] = []
        var clients: [NearbyTCPConnection] = []
        defer { clients.forEach { $0.close() }; bridge.stop() }
        _ = try await bridge.startGuest(roomID: room, laneConnect: { lane in
            requested.append(lane)
            // Native setup is deliberately rejected after recording the selector.
            throw NearbyConnectionError.unavailable
        })
        for lane in NearbyLaneRequest.Lane.allCases where lane != .metadata {
            let client = NearbyTCPConnection(port: 60_119 + UInt16(lane.rawValue))
            clients.append(client)
            _ = try await client.read(maximum: 1) // EOF follows the rejected native setup.
        }
        #expect(requested == [.realtime, .control, .asset, .admission])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func admissionReplyDrainsUntilPeerClosesOrDeadline(peerCloses: Bool) async throws {
        let roomID = UUID()
        let record = BluetoothRoomRecord(roomID: roomID, guideID: UUID(), name: "Tour", isAndroid: false, isLocked: true)
        let reply = Data(repeating: 42, count: RoomAdmissionV2.challengeSize + RoomAdmissionV2.replySize)
        let local = BufferedNearbyTestConnection(bytes: reply, waitsForClose: false)
        let remote = BufferedNearbyTestConnection(
            bytes: try NearbyLaneRequest(lane: .admission, roomID: roomID).encode(), waitsForClose: true)
        let bridge = NearbySocketBridge(localConnect: { _ in local })
        defer { bridge.stop() }
        await withCheckedContinuation { continuation in
            local.onEOF = { continuation.resume() }
            bridge.accept(remote) { record }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!remote.closed)
        #expect(remote.pendingOutput == Data([0]) + reply)
        if peerCloses { remote.close() }
        else {
            try await Task.sleep(for: .seconds(5))
            #expect(remote.closed)
        }
    }

    @Test func metadataRoundtripsThroughRealTCP() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "جولة 🌍", isAndroid: false, isLocked: false)
        let bridge = NearbySocketBridge()
        let listener = try TestNearbyListener(bridge: bridge, record: record)
        defer { listener.close(); bridge.stop() }
        let port = try await listener.start()
        let received = try await NearbySocketBridge.readRecord { NearbyTCPConnection(port: port) }
        #expect(received == record)
    }

    @Test("Native queue classifies signed speech separately from signed handshake frames",
          arguments: [SessionMessageKind.audioFrame, .authChallenge, .welcome])
    func signedRealtimeClassification(kind: SessionMessageKind) throws {
        let session = UUID()
        let guide = UUID()
        let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: session)
        let envelope = try SessionEnvelope(lane: kind.requiredLane, kind: kind, sequence: 0,
            sessionID: session, senderID: guide, payload: Data([1, 2, 3]))
        let sealed = try SessionFrameSealer(credential: credential).seal(envelope, streamID: UUID())
        let signer = GuideFrameSigner(sessionID: session, guideID: guide)
        let signed = try signer.sign(sealed).encode()
        #expect(try NearbySocketBridge.realtimeFrameIsAudio(sealed.encode()) == (kind == .audioFrame))
        #expect(try NearbySocketBridge.realtimeFrameIsAudio(signed) == (kind == .audioFrame))
        for count in 0..<signed.count {
            #expect(throws: (any Error).self) { try NearbySocketBridge.realtimeFrameIsAudio(Data(signed.prefix(count))) }
        }
        #expect(throws: (any Error).self) { try NearbySocketBridge.realtimeFrameIsAudio(signed + Data([0])) }
        var wrongLength = signed
        wrongLength[7] ^= 1
        #expect(throws: (any Error).self) { try NearbySocketBridge.realtimeFrameIsAudio(wrongLength) }
        var wrongInnerMagic = signed
        wrongInnerMagic[8] ^= 1
        #expect(throws: (any Error).self) { try NearbySocketBridge.realtimeFrameIsAudio(wrongInnerMagic) }

        // Classification does not make tampered signatures authoritative: only the guest lane
        // verifies the admitted guide key before AEAD and delivery.
        var invalidSignature = signed
        invalidSignature[invalidSignature.count - 1] ^= 1
        #expect(try NearbySocketBridge.realtimeFrameIsAudio(invalidSignature) == (kind == .audioFrame))
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guide)
        #expect(throws: (any Error).self) { try verifier.verify(invalidSignature) }
    }

    @Test func wrongRoomNeverOpensALocalLane() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false)
        var opened = false
        let bridge = NearbySocketBridge(localConnect: { port in opened = true; return NearbyTCPConnection(port: port) })
        let listener = try TestNearbyListener(bridge: bridge, record: record)
        defer { listener.close(); bridge.stop() }
        let port = try await listener.start()
        let guest = NearbyTCPConnection(port: port)
        defer { guest.close() }
        try await guest.write(try NearbyLaneRequest(lane: .admission, roomID: UUID()).encode())
        let result = try await guest.read(maximum: 1)
        #expect(result.isEmpty)
        #expect(!opened)
    }

    @Test func realAdmissionPreservesOpenLockEditUnlockThroughBothAdapters() async throws {
        let roomID = UUID()
        let guideID = UUID()
        let signer = GuideFrameSigner(sessionID: roomID, guideID: guideID)
        let record = BluetoothRoomRecord(roomID: roomID, guideID: guideID, name: "Tour", isAndroid: false, isLocked: false, admissionVersion: 2)
        let admission = RoomAdmissionTransport(port: 56023)
        try admission.start(sessionID: roomID, sessionCode: "23456789AB", signer: signer)
        let guide = NearbySocketBridge(localConnect: { port in
            #expect(port == 50_003)
            return NearbyTCPConnection(port: 56023)
        })
        let listener = try TestNearbyListener(bridge: guide, record: record)
        let guest = NearbySocketBridge()
        defer { guest.stop(); listener.close(); guide.stop(); admission.stop() }
        let port = try await listener.start()
        let host = try await guest.startGuest(roomID: roomID) { NearbyTCPConnection(port: port) }
        #expect(host == "127.0.0.1")
        #expect(try await join(roomID, guideID: guideID, code: nil) == "23456789AB")
        try admission.update(policy: RoomAccessPolicy(sessionID: roomID, code: "1234"))
        await #expect(throws: (any Error).self) { try await join(roomID, guideID: guideID, code: "wrong") }
        #expect(try await join(roomID, guideID: guideID, code: "1234") == "23456789AB")
        try admission.update(policy: RoomAccessPolicy(sessionID: roomID, code: "Edited!"))
        await #expect(throws: (any Error).self) { try await join(roomID, guideID: guideID, code: "1234") }
        #expect(try await join(roomID, guideID: guideID, code: "Edited!") == "23456789AB")
        try admission.update(policy: RoomAccessPolicy(sessionID: roomID, code: nil))
        #expect(try await join(roomID, guideID: guideID, code: nil) == "23456789AB")
    }

    @concurrent private func join(_ roomID: UUID, guideID: UUID, code: String?) async throws -> String {
        try RoomAdmissionTransport().join(host: "127.0.0.1", sessionID: roomID, expectedGuideID: guideID, code: code).mediaSecret
    }
}

@MainActor
private final class RouteBluetoothTestRadio: BluetoothSessionDiscoveryInterface {
    var onRoom: ((BluetoothRoomRecord) -> Void)?
    var onLost: ((UUID) -> Void)?
    let record: BluetoothRoomRecord
    var joinedRoom: UUID?
    var connectCalls = 0
    var requestedLanes: [NearbyLaneRequest.Lane] = []
    init(record: BluetoothRoomRecord) { self.record = record }
    func canConnect(roomID: UUID) -> Bool { record.roomID == roomID }
    func connect(roomID: UUID) async throws -> any NearbyByteConnection {
        connectCalls += 1
        let bytes = try record.encode()
        return BufferedNearbyTestConnection(bytes: Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes, waitsForClose: false)
    }
    func connect(roomID: UUID, lane: NearbyLaneRequest.Lane) async throws -> any NearbyByteConnection {
        requestedLanes.append(lane)
        return try await connect(roomID: roomID)
    }
    func setJoinedRoom(_ roomID: UUID?) { joinedRoom = roomID }
    func setMode(_ mode: BluetoothDiscoveryMode) {}
    func stop() {}
    func publish(_ record: BluetoothRoomRecord?) {}
}

@MainActor
private final class RouteAwareTestRadio: NearbyRoomTransport {
    var onRoom: ((BluetoothRoomRecord) -> Void)?
    var onLost: ((UUID) -> Void)?
    var onError: ((String) -> Void)?
    var connectCalls = 0
    var record: BluetoothRoomRecord?
    var connectionError: (any Error)?
    func connect(roomID: UUID) async throws -> any NearbyByteConnection {
        connectCalls += 1
        if let connectionError { throw connectionError }
        guard let record else { throw NearbyConnectionError.unavailable }
        let bytes = try record.encode()
        return BufferedNearbyTestConnection(bytes: Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes, waitsForClose: false)
    }
    func setMode(_ mode: BluetoothDiscoveryMode) {}
    func stop() {}
    func publish(_ record: BluetoothRoomRecord?) {}
}

@MainActor
private final class GatewayTestConnector: GuideLaneConnector {
    var requests: [(NearbyLaneRequest.Lane, UUID)] = []
    var connections: [BufferedNearbyTestConnection] = []
    func connect(lane: NearbyLaneRequest.Lane, roomID: UUID) async throws -> any NearbyByteConnection {
        requests.append((lane, roomID))
        let connection = BufferedNearbyTestConnection(bytes: Data(), waitsForClose: true)
        connections.append(connection)
        return connection
    }
}

/// Models native output that close can discard before the peer consumes it.
@MainActor
private final class BufferedNearbyTestConnection: NearbyByteConnection {
    private var bytes: Data
    private let waitsForClose: Bool
    private var reader: CheckedContinuation<Data, any Error>?
    var onEOF: (() -> Void)?
    private(set) var pendingOutput = Data()
    private(set) var closed = false
    init(bytes: Data, waitsForClose: Bool) { self.bytes = bytes; self.waitsForClose = waitsForClose }
    func read(maximum: Int) async throws -> Data {
        if closed { return Data() }
        if !bytes.isEmpty {
            let result = Data(bytes.prefix(maximum)); bytes.removeFirst(result.count)
            return result
        }
        if waitsForClose {
            return try await withCheckedThrowingContinuation { reader = $0 }
        }
        let notify = onEOF; onEOF = nil; notify?()
        return Data()
    }
    func write(_ bytes: Data) async throws {
        guard !closed else { throw NearbyConnectionError.closed }
        pendingOutput.append(bytes)
    }
    func close() {
        closed = true; pendingOutput.removeAll()
        reader?.resume(returning: Data()); reader = nil
    }
}

@MainActor
private final class TestNearbyListener {
    private let listener: NWListener
    private var ready: CheckedContinuation<UInt16, any Error>?
    init(bridge: NearbySocketBridge, record: BluetoothRoomRecord) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in bridge.accept(NearbyTCPConnection(connection)) { record } }
        }
        listener.stateUpdateHandler = { [weak self] state in
            let owner = self
            Task { @MainActor in
                guard let owner else { return }
                switch state {
                case .ready:
                    guard let port = owner.listener.port?.rawValue else { return }
                    owner.ready?.resume(returning: port); owner.ready = nil
                case .failed(let error): owner.ready?.resume(throwing: error); owner.ready = nil
                case .cancelled: owner.ready?.resume(throwing: CancellationError()); owner.ready = nil
                default: break
                }
            }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: .main)
        }
    }
    func close() { listener.cancel() }
}
