import Foundation
import Network
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite(.serialized)
@MainActor
struct NearbySocketBridgeTests {
    @Test func metadataRoundtripsThroughRealTCP() async throws {
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "جولة 🌍", isAndroid: false, isLocked: false)
        let bridge = NearbySocketBridge()
        let listener = try TestNearbyListener(bridge: bridge, record: record)
        defer { listener.close(); bridge.stop() }
        let port = try await listener.start()
        let received = try await NearbySocketBridge.readRecord { NearbyTCPConnection(port: port) }
        #expect(received == record)
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
        let record = BluetoothRoomRecord(roomID: roomID, guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false)
        let admission = RoomAdmissionTransport(port: 56023)
        try admission.start(sessionID: roomID, sessionCode: "23456789AB")
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
        #expect(try await join(roomID, code: nil) == "23456789AB")
        try admission.update(policy: RoomAccessPolicy(sessionID: roomID, code: "1234"))
        await #expect(throws: (any Error).self) { try await join(roomID, code: "wrong") }
        #expect(try await join(roomID, code: "1234") == "23456789AB")
        try admission.update(policy: RoomAccessPolicy(sessionID: roomID, code: "Edited!"))
        await #expect(throws: (any Error).self) { try await join(roomID, code: "1234") }
        #expect(try await join(roomID, code: "Edited!") == "23456789AB")
        try admission.update(policy: RoomAccessPolicy(sessionID: roomID, code: nil))
        #expect(try await join(roomID, code: nil) == "23456789AB")
    }

    @concurrent private func join(_ roomID: UUID, code: String?) async throws -> String {
        try RoomAdmissionTransport().join(host: "127.0.0.1", sessionID: roomID, code: code)
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
