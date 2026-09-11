import CryptoKit
import Foundation
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
