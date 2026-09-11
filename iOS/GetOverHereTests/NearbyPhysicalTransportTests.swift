import CryptoKit
import Foundation
import Network
import Testing
import TourSessionCore
@testable import GetOverHere

/// Opt-in physical fixture compatible with NearbyPhysicalTransportTest on Android.
/// Default simulator runs skip it, rather than claiming a radio pass.
@MainActor
struct NearbyPhysicalTransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOH_NEARBY_ROOM"] != nil))
    func bluetoothCarriesAdmissionControlAssetsAndNativeAudio() async throws {
        #if targetEnvironment(simulator)
        throw FixtureFailure.physicalDeviceRequired
        #else
        let env = ProcessInfo.processInfo.environment
        let room = try #require(env["GOH_NEARBY_ROOM"].flatMap(UUID.init(uuidString:)))
        let role = try #require(env["GOH_NEARBY_ROLE"])
        try #require(role == "guide" || role == "guest")
        let guide = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let participant = role == "guide" ? guide : UUID()
        let radio = BluetoothRoomDiscovery()
        let bridge = NearbySocketBridge()
        let admission = RoomAdmissionTransport()
        let audio = UDPAudioPlane()
        let control = LocalSessionControlTransport()
        let assets = LocalSessionAssetTransport()
        let progress = Progress()
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let chunk = try AssetChunkPayload(sha256: hash, offset: 0, totalLength: UInt64(bytes.count), bytes: bytes)
        defer {
            audio.clearSession(); control.clearSession(); assets.clearSession()
            admission.stop(); bridge.stop(); radio.stop()
        }
        let secret: String
        let authentication: SessionGuideAuthentication
        if role == "guide" {
            secret = "23456789AB"
            let signer = GuideFrameSigner(sessionID: room, guideID: guide)
            authentication = .guide(signer)
            try admission.start(sessionID: room, sessionCode: secret, signer: signer)
            try admission.update(policy: RoomAccessPolicy(sessionID: room, code: "2468"))
        } else {
            radio.setMode(.browsing)
            try await waitUntil(seconds: 30) { radio.canConnect(roomID: room) }
            radio.setJoinedRoom(room)
            let host = try await bridge.startGuest(roomID: room, laneConnect: { lane in
                try await radio.connect(roomID: room, lane: lane)
            })
            let admitted = try await admit(host: host, room: room, guideID: guide)
            secret = admitted.mediaSecret
            authentication = .guest(try GuideFrameVerifier(pinnedPublicKey: admitted.guideIdentity.publicKey,
                sessionID: room, guideID: guide))
        }
        let credential = try await credential(secret: secret, room: room)
        audio.configureSession(sessionID: room, participantID: participant, displayName: role, platform: .iOS, credential: credential)
        control.configureSession(sessionID: room, participantID: participant, displayName: role, platform: .iOS, credential: credential)
        assets.configureSession(sessionID: room, participantID: participant, displayName: role, platform: .iOS, credential: credential)
        audio.configureGuideAuthentication(authentication)
        control.configureGuideAuthentication(authentication)
        assets.configureGuideAuthentication(authentication)
        if role == "guide" {
            audio.setSessionEventHandler { event in
                if case .joined = event { Task { @MainActor in progress.joined = true } }
            }
            try audio.startBroadcasting(channelID: room.uuidString, quality: .standard)
            try control.startGuide(); try assets.startGuide()
            radio.publish(BluetoothRoomRecord(roomID: room, guideID: guide, name: "Physical nearby fixture", isAndroid: false, isLocked: true, admissionVersion: 2))
            radio.setMode(.advertising)
            for frame in 0..<3_000 {
                var pcm = Data(capacity: 640)
                for index in 0..<320 {
                    var sample = Int16(sin(Double(frame * 320 + index) * 440 * 2 * .pi / 16_000) * 8_000).littleEndian
                    withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
                }
                audio.sendAudio(pcm)
                if frame % 50 == 0 {
                    control.send(kind: .visualFocusSnapshot, payload: VisualFocusSnapshotPayload(stateVersion: UInt64(frame), mode: .pointer).encode())
                    assets.send(kind: .assetChunk, payload: try chunk.encode(), to: nil)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(progress.joined)
        } else {
            control.setEventHandler { event in
                guard case let .envelopeReceived(envelope) = event, envelope.kind == .visualFocusSnapshot else { return }
                do {
                    let focus = try VisualFocusSnapshotPayload.decode(envelope.payload)
                    Task { @MainActor in progress.pointer = focus.mode == .pointer }
                } catch { Issue.record(error) }
            }
            assets.setEventHandler { event in
                guard case let .envelopeReceived(envelope) = event, envelope.kind == .assetChunk else { return }
                do {
                    let received = try AssetChunkPayload.decode(envelope.payload)
                    Task { @MainActor in progress.asset = received.sha256 == hash && received.bytes == bytes }
                } catch { Issue.record(error) }
            }
            control.hostIP = "127.0.0.1"; assets.hostIP = "127.0.0.1"; audio.hostIP = "127.0.0.1"
            control.startGuest(); assets.startGuest()
            audio.startListening(channelID: room.uuidString) { pcm in
                if pcm.contains(where: { $0 != 0 }) { Task { @MainActor in progress.audioFrames += 1 } }
            }
            try await waitUntil(seconds: 30) { progress.pointer && progress.asset && progress.audioFrames >= 100 }
            #expect(progress.pointer && progress.asset && progress.audioFrames >= 100)
        }
        #endif
    }

    @MainActor private final class Progress {
        var joined = false
        var pointer = false
        var asset = false
        var audioFrames = 0
    }
    private enum FixtureFailure: Error { case physicalDeviceRequired, timeout }
    private func waitUntil(seconds: Int, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard clock.now < deadline else { throw FixtureFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @concurrent private func admit(host: String, room: UUID, guideID: UUID) async throws -> AdmittedRoomCredentials {
        try RoomAdmissionTransport().join(host: host, sessionID: room, expectedGuideID: guideID, code: "2468")
    }
    @concurrent private func credential(secret: String, room: UUID) async throws -> SessionCredential {
        try SessionCredential.derive(shortCode: secret, sessionID: room)
    }
}

// Test-only GBB1. One verified stream per listener, never a production protocol.
@MainActor
struct BluetoothSpeedTests {
    @Test func protocolSmoke() async throws {
        let server = try NWListener(using: NearbyTCPConnection.parameters(), on: .any)
        var accepted: NearbyTCPConnection?
        var ready = false
        var failure: (any Error)?
        var serving: Task<Void, any Error>?
        server.stateUpdateHandler = { state in Task { @MainActor in
            if case .ready = state { ready = true }
            if case let .failed(error) = state { failure = error }
        } }
        server.newConnectionHandler = { connection in Task { @MainActor in
            let peer = NearbyTCPConnection(connection)
            accepted = peer
            serving = Task { try await serve(peer) }
        } }
        server.start(queue: .main)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        defer { accepted?.close(); serving?.cancel(); server.cancel() }
        while !ready {
            if let failure { throw failure }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(server.port)
        let guest = NearbyTCPConnection(port: port.rawValue)
        let timeout = Task { try await Task.sleep(for: .seconds(10)); guest.close(); accepted?.close() }
        defer { timeout.cancel(); guest.close() }
        try await benchmark(guest, count: 1024)
        try await serving?.value
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOH_SPEED_ROLE"] != nil))
    func measure() async throws {
        #if targetEnvironment(simulator)
        throw SpeedFailure.invalid
        #else
        let env = ProcessInfo.processInfo.environment
        let role = try #require(env["GOH_SPEED_ROLE"])
        let room = try #require(env["GOH_SPEED_ROOM"].flatMap(UUID.init(uuidString:)))
        let count = try #require(env["GOH_SPEED_BYTES"].flatMap(Int.init))
        let peers = try #require(env["GOH_SPEED_PEERS"].flatMap(Int.init))
        try #require((1...2).contains(peers) && (1024...262144).contains(count))
        let radio = BluetoothRoomDiscovery()
        var listener: NWListener?
        var connections: [any NearbyByteConnection] = []
        var completed = 0
        var failure: (any Error)?
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(180))
            failure = SpeedFailure.timeout
            connections.forEach { $0.close() }
            listener?.cancel()
        }
        defer { timeout.cancel(); connections.forEach { $0.close() }; listener?.cancel(); radio.stop() }
        if role == "guide" {
            let parameters = NearbyTCPConnection.parameters()
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 50002)
            let server = try NWListener(using: parameters)
            listener = server
            var ready = false
            server.stateUpdateHandler = { state in
                Task { @MainActor in
                    if case .ready = state { ready = true }
                    if case let .failed(error) = state { failure = error }
                }
            }
            server.newConnectionHandler = { accepted in
                Task { @MainActor in
                    guard connections.count < peers else { accepted.cancel(); return }
                    let connection = NearbyTCPConnection(accepted)
                    connections.append(connection)
                    do { try await serve(connection); completed += 1 }
                    catch { failure = error }
                }
            }
            server.start(queue: .main)
            while !ready { if let failure { throw failure }; try await Task.sleep(for: .milliseconds(20)) }
            radio.publish(BluetoothRoomRecord(roomID: room, guideID: UUID(), name: "Bluetooth speed test", isAndroid: false, isLocked: false))
            radio.setMode(.advertising)
            while completed < peers { if let failure { throw failure }; try await Task.sleep(for: .milliseconds(20)) }
        } else {
            radio.setMode(.browsing)
            while !radio.canConnect(roomID: room) { if let failure { throw failure }; try await Task.sleep(for: .milliseconds(20)) }
            radio.setJoinedRoom(room)
            let connection = try await radio.connect(roomID: room, lane: .asset)
            connections.append(connection)
            try await connection.write(NearbyLaneRequest(lane: .asset, roomID: room).encode())
            try #require(try await connection.readExactly(1) == Data([0]))
            try await benchmark(connection, count: count)
        }
        if let failure { throw failure }
        #endif
    }

    private enum SpeedFailure: Error { case invalid, timeout }
    private func payload(_ count: Int) -> Data { Data((0..<count).map { UInt8(($0 * 31 + 17) & 255) }) }
    private func integer(_ value: UInt64, width: Int = 4) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func number(_ connection: any NearbyByteConnection, width: Int = 4) async throws -> UInt64 {
        try await connection.readExactly(width).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private func receive(_ connection: any NearbyByteConnection, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count { data.append(try await connection.readExactly(min(16384, count - data.count))) }
        return data
    }
    private func send(_ connection: any NearbyByteConnection, data: Data) async throws {
        for offset in stride(from: 0, to: data.count, by: 16384) {
            try await connection.write(data.subdata(in: offset..<min(offset + 16384, data.count)))
        }
    }
    private func serve(_ connection: any NearbyByteConnection) async throws {
        try #require(try await number(connection) == 0x47424231)
        try await connection.write(integer(0x47424231))
        while true {
            let mode = try await number(connection)
            if mode == 0 {
                try await connection.write(integer(0))
                try #require(try await connection.read(maximum: 1).isEmpty)
                return
            }
            let count = Int(try await number(connection))
            try #require((1...3).contains(mode) && (1...262144).contains(count))
            try await connection.write(integer(mode))
            let expected = payload(count)
            if mode == 1 {
                try await send(connection, data: expected)
                try #require(try await number(connection) == UInt64(count))
            } else {
                let start = DispatchTime.now().uptimeNanoseconds
                let data = try await receive(connection, count: count)
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                try #require(data == expected)
                try await connection.write(mode == 3 ? data : integer(elapsed, width: 8))
            }
        }
    }
    private func report(_ row: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("BLUETOOTH_SPEED " + String(decoding: bytes, as: UTF8.self))
    }
    private func benchmark(_ connection: any NearbyByteConnection, count: Int) async throws {
        try await connection.write(integer(0x47424231))
        try #require(try await number(connection) == 0x47424231)
        var samples: [Double] = []
        for _ in 0..<50 {
            try await connection.write(integer(3) + integer(64))
            try #require(try await number(connection) == 3)
            let start = DispatchTime.now().uptimeNanoseconds
            try await connection.write(payload(64))
            let echo = try await receive(connection, count: 64)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            try #require(echo == payload(64))
        }
        try report(["phase": "idle_rtt", "samples_ms": samples])
        for round in 1...3 {
            for mode in 1...2 {
                try await connection.write(integer(UInt64(mode)) + integer(UInt64(count)))
                try #require(try await number(connection) == UInt64(mode))
                let elapsed: UInt64
                if mode == 1 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let data = try await receive(connection, count: count)
                    elapsed = DispatchTime.now().uptimeNanoseconds - start
                    try #require(data == payload(count))
                    try await connection.write(integer(UInt64(count)))
                } else {
                    try await send(connection, data: payload(count))
                    elapsed = try await number(connection, width: 8)
                }
                try report(["phase": mode == 1 ? "guide_to_guest" : "guest_to_guide", "round": round,
                            "bytes": count, "receive_ns": elapsed, "mbps": Double(count) * 8000 / Double(elapsed)])
            }
        }
        try await connection.write(integer(0))
        try #require(try await number(connection) == 0)
        connection.close()
    }
}
