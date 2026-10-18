import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// The far iPhone guest's real lanes in relay mode against a real bridge (ADR-081 P4, ADR-083), over loopback;
/// mirrors RelayFarGuestTest.kt.
@MainActor
@Suite("Relay far guest (ADR-081 P4)", .serialized)
struct RelayFarGuestTests {
    let session = UUID(), guideID = UUID(), bridgeID = UUID(), stream = UUID()
    let credential: SessionCredential
    let signer: GuideFrameSigner
    let sealer: SessionFrameSealer
    let hub: RelayHub
    let verifier: GuideFrameVerifier
    private let sequence = GuideSequenceCounter()

    init() throws {
        credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: session)
        signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        sealer = SessionFrameSealer(credential: credential)
        verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guideID)
        hub = RelayHub(bridgeID: bridgeID, verifier: verifier, credential: credential,
                       onRouteFault: { _, reason in Issue.record("route fault: \(reason)") }, onIslandRevoked: { _ in })
    }

    func frame(_ kind: SessionMessageKind, _ payload: Data = Data(count: 8)) throws -> Data {
        try signer.sign(sealer.seal(SessionEnvelope(lane: kind.requiredLane, kind: kind, sequence: sequence.next(),
            sessionID: session, senderID: guideID, payload: payload), streamID: stream)).encode()
    }

    func assign(_ generation: UInt64) throws {
        let payload = try BridgeAssignmentPayload(generation: generation, bridgeID: bridgeID, bridgePlatform: .iOS,
                                                  leaseExpiresAtMilliseconds: .max, standbyIDs: []).encode()
        hub.onUpstreamFrame(lane: .control, frame: try frame(.bridgeAssignment, payload), receivedAtMilliseconds: 0, nowMilliseconds: 0)
    }

    func waitFor<T>(_ seconds: Double = 5, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RelayLaneServer.EndOfStream()
    }

    @Test func farGuestJoinsThroughBridgeAndReceivesGuideFrames() async throws {
        try assign(1)
        let forwarded = RelayBridgeTests.Faults()
        let server = try RelayLaneServer(lane: .control, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub, onUpstream: { forwarded.append($0.farParticipantID.uuidString) })
        defer { server.close() }
        let presentation = try frame(.presentationSnapshot)
        hub.onUpstreamFrame(lane: .control, frame: presentation, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        let guest = LocalSessionControlTransport(port: server.port)
        defer { guest.stop() }
        let log = EventLog<SessionControlEvent>()
        guest.configureGuideAuthentication(.guest(verifier))
        let me = UUID()
        guest.configureSession(sessionID: session, participantID: me, displayName: "Far guest", platform: .iOS, credential: credential)
        guest.hostIP = "127.0.0.1"
        guest.setRelayRoute(RelayRoute(host: RelayHostAdvert(hostID: bridgeID, bridgeGeneration: 1), guideID: guideID))
        guest.setEventHandler { event in Task { @MainActor in log.items.append(event) } }
        guest.startGuest()
        func envelopes() -> [SessionEnvelope] { log.items.compactMap { if case let .envelopeReceived(e) = $0 { e } else { nil } } }
        let replayed = try await waitFor { envelopes().count >= 2 ? envelopes() : nil }
        #expect(Set(replayed.map(\.kind)) == [.bridgeAssignment, .presentationSnapshot])
        #expect(replayed.allSatisfy { $0.senderID == guideID }, "guide frames keep the guide as sender through the bridge")
        guest.send(kind: .audioStatus, payload: AudioReadinessPayload(status: .playing, revision: 1).encode())
        _ = try await waitFor { forwarded.values.isEmpty ? nil : true }
        #expect(forwarded.values == [me.uuidString], "W5: the guest's own status does not end its lane")
        hub.onUpstreamFrame(lane: .control, frame: try frame(.targetSnapshot), receivedAtMilliseconds: 0, nowMilliseconds: 0)
        let live = try await waitFor { envelopes().first { $0.kind == .targetSnapshot } }
        #expect(live.senderID == guideID)
    }

    @Test func staleGenerationNeverConnects() async throws {
        try assign(2)
        let server = try RelayLaneServer(lane: .control, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub)
        defer { server.close() }
        let guest = LocalSessionControlTransport(port: server.port)
        defer { guest.stop() }
        let log = EventLog<SessionControlEvent>()
        guest.configureGuideAuthentication(.guest(verifier))
        guest.configureSession(sessionID: session, participantID: UUID(), displayName: "Far guest", platform: .iOS, credential: credential)
        guest.hostIP = "127.0.0.1"
        guest.setRelayRoute(RelayRoute(host: RelayHostAdvert(hostID: bridgeID, bridgeGeneration: 1), guideID: guideID))
        guest.setEventHandler { event in Task { @MainActor in log.items.append(event) } }
        guest.startGuest()
        let ended = try await waitFor { log.items.first { if case .connected = $0 { false } else { true } } }
        #expect(!log.items.contains { if case .connected = $0 { true } else { false } }, "got \(ended)")
    }

    @Test func farGuestGetsGuideManifestAndBridgeChunks() async throws {
        try assign(1)
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = try TourPackManifestPayload(packID: UUID(), manifestVersion: 1, displayName: "Tour", assets: [
            TourAssetDescriptor(assetID: "slide", kind: .slide, sha256: hash, byteLength: UInt64(bytes.count), order: 0, mimeType: "image/jpeg")])
        hub.onUpstreamFrame(lane: .asset, frame: try frame(.tourPackManifest, manifest.encode()), receivedAtMilliseconds: 0, nowMilliseconds: 0)
        let server = try RelayLaneServer(lane: .asset, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub, assetFile: { $0 == hash ? url : nil })
        defer { server.close() }
        let guest = LocalSessionAssetTransport(port: server.port)
        defer { guest.stop() }
        let log = EventLog<SessionAssetEvent>()
        guest.configureGuideAuthentication(.guest(verifier))
        guest.configureSession(sessionID: session, participantID: UUID(), displayName: "Far guest", platform: .iOS, credential: credential)
        guest.hostIP = "127.0.0.1"
        guest.setRelayRoute(RelayRoute(host: RelayHostAdvert(hostID: bridgeID, bridgeGeneration: 1), guideID: guideID))
        guest.setEventHandler { event in Task { @MainActor in log.items.append(event) } }
        guest.startGuest()
        func envelopes() -> [SessionEnvelope] { log.items.compactMap { if case let .envelopeReceived(e) = $0 { e } else { nil } } }
        let relayed = try await waitFor { envelopes().first }
        #expect(relayed.kind == .tourPackManifest && relayed.senderID == guideID)
        var received = Data()
        while received.count < bytes.count {
            let before = envelopes().count
            guest.send(kind: .assetRequest, payload: try AssetRequestPayload(sha256: hash, offset: UInt64(received.count)).encode(), to: nil)
            let chunk = try await waitFor { envelopes().count > before ? envelopes().last : nil }
            #expect(chunk.kind == .assetChunk && chunk.senderID == bridgeID, "chunks come from the bridge cache, bridge-sealed")
            received.append(try AssetChunkPayload.decode(chunk.payload).bytes)
        }
        #expect(received == bytes)
    }
}

@MainActor
final class EventLog<Event> {
    var items: [Event] = []
}
