import CryptoKit
import Darwin
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// iPhone bridge (ADR-081 P4): RelayHub fan-out and RelayLaneServer over loopback; mirrors RelayHubTest.kt and
/// RelayLaneServerTest.kt.
@Suite("Relay bridge (ADR-081 P4)", .serialized)
struct RelayBridgeTests {
    final class Writer: RelayChildWriter, @unchecked Sendable {
        private let lock = NSLock()
        private let capacity: Int
        private var stored: [Data] = []
        private var isClosed = false
        init(capacity: Int = .max) { self.capacity = capacity }
        var frames: [Data] { lock.withLock { stored } }
        var closed: Bool { lock.withLock { isClosed } }
        func enqueue(_ frame: Data) -> Bool {
            lock.withLock {
                guard stored.count < capacity, !isClosed else { return false }
                stored.append(frame)
                return true
            }
        }
        func close() { lock.withLock { isClosed = true } }
    }

    final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var values: [String] { lock.withLock { stored } }
        func append(_ value: String) { lock.withLock { stored.append(value) } }
    }

    let session = UUID(), guideID = UUID(), bridgeID = UUID(), stream = UUID()
    let credential: SessionCredential
    let signer: GuideFrameSigner
    let sealer: SessionFrameSealer
    let faults = Faults()
    let hub: RelayHub
    private let sequence = GuideSequenceCounter()

    init() throws {
        credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: session)
        signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        sealer = SessionFrameSealer(credential: credential)
        let faults = faults
        hub = RelayHub(bridgeID: bridgeID,
                       verifier: try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guideID),
                       credential: credential, onRouteFault: { _, reason in faults.append(reason) }, onIslandRevoked: { _ in })
    }

    func frame(_ kind: SessionMessageKind, _ payload: Data = Data(count: 8), by other: GuideFrameSigner? = nil) throws -> Data {
        let envelope = try SessionEnvelope(lane: kind.requiredLane, kind: kind, sequence: sequence.next(), sessionID: session,
                                           senderID: guideID, payload: payload)
        return try (other ?? signer).sign(sealer.seal(envelope, streamID: stream)).encode()
    }

    func assign(_ bridge: UUID, generation: UInt64) throws {
        let payload = try BridgeAssignmentPayload(generation: generation, bridgeID: bridge, bridgePlatform: .iOS,
                                                  leaseExpiresAtMilliseconds: .max, standbyIDs: []).encode()
        hub.onUpstreamFrame(lane: .control, frame: try frame(.bridgeAssignment, payload), receivedAtMilliseconds: 0, nowMilliseconds: 0)
    }

    // MARK: - RelayHub

    @Test func fansOutVerifiedFramesPerLaneAndDropsDuplicates() throws {
        let a = Writer(), b = Writer(), control = Writer()
        hub.attach(lane: .realtime, writer: a); hub.attach(lane: .realtime, writer: b); hub.attach(lane: .control, writer: control)
        let audio = try frame(.audioBatch)
        hub.onUpstreamFrame(lane: .realtime, frame: audio, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        hub.onUpstreamFrame(lane: .realtime, frame: audio, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        #expect(a.frames == [audio] && b.frames == [audio])
        #expect(control.frames.isEmpty)
        #expect(hub.counters.duplicates == 1)
        #expect(faults.values.isEmpty)
    }

    @Test func forgedLateOrMisroutedFramesNeverReachPeers() throws {
        let peer = Writer(), control = Writer()
        hub.attach(lane: .realtime, writer: peer); hub.attach(lane: .control, writer: control)
        hub.onUpstreamFrame(lane: .realtime, frame: try frame(.audioBatch, by: GuideFrameSigner(sessionID: session, guideID: guideID)),
                            receivedAtMilliseconds: 0, nowMilliseconds: 0)
        hub.onUpstreamFrame(lane: .realtime, frame: try frame(.audioBatch), receivedAtMilliseconds: 0, nowMilliseconds: 51)
        hub.onUpstreamFrame(lane: .control, frame: try frame(.audioBatch), receivedAtMilliseconds: 0, nowMilliseconds: 0)
        #expect(faults.values.count == 2)
        #expect(hub.counters.expired == 1)
        #expect(peer.frames.isEmpty && control.frames.isEmpty)
    }

    @Test func latePeersGetCachedControlStateAndManifest() throws {
        let presentation = try frame(.presentationSnapshot)
        hub.onUpstreamFrame(lane: .control, frame: presentation, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        let manifest = try frame(.tourPackManifest)
        hub.onUpstreamFrame(lane: .asset, frame: manifest, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        hub.onUpstreamFrame(lane: .asset, frame: try frame(.assetChunk), receivedAtMilliseconds: 0, nowMilliseconds: 0)
        let control = Writer(), asset = Writer()
        hub.attach(lane: .control, writer: control); hub.attach(lane: .asset, writer: asset)
        #expect(control.frames == [presentation])
        #expect(asset.frames == [manifest], "chunks for the bridge are never relayed")
    }

    @Test func anotherAssignmentRevokesAndWatermarkNeverGoesBack() throws {
        let peer = Writer()
        hub.attach(lane: .realtime, writer: peer)
        try assign(bridgeID, generation: 5)
        #expect(hub.assignment?.generation == 5)
        try assign(UUID(), generation: 6)
        #expect(hub.assignment == nil && peer.closed)
        try assign(bridgeID, generation: 5)
        #expect(hub.assignment == nil, "a replayed older assignment cannot reinstate this bridge")
        try assign(bridgeID, generation: 7)
        #expect(hub.assignment?.generation == 7)
    }

    // MARK: - RelayLaneServer

    /// A far guest's ADR-083 handshake; returns the verified assignment and the open socket.
    func join(_ server: RelayLaneServer, lane: SessionLane, generation: UInt64 = 1, with key: SessionCredential? = nil,
              participant: UUID = UUID()) throws -> (BridgeAssignmentPayload, ManagedSocket) {
        let socket = try Self.connect(port: server.port)
        let credential = key ?? self.credential
        let opener = SessionFrameOpener(credential: credential)
        func open(_ data: Data) throws -> SessionEnvelope {
            guard case let .opened(envelope) = try opener.open(SealedSessionEnvelope.decode(data)) else { throw RelayLaneServer.EndOfStream() }
            return envelope
        }
        let challenge = try AuthChallengePayload.decode(open(RelayLaneServer.readFrame(socket.fd, 65_536)).payload)
        let context = RelayLaneContext(sessionID: session, guideID: guideID, host: RelayHostAdvert(hostID: bridgeID, bridgeGeneration: generation),
                                       participantID: participant, lane: lane)
        let clientNonce = SessionAuthenticator.randomNonce()
        let proof = try RelayLaneAuthenticator.guestProof(credential: credential, context: context, challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce, role: .guest, platform: .iOS, capabilities: 0, displayName: "Far guest")
        let hello = try HelloPayload(role: .guest, platform: .iOS, capabilities: 0, displayName: "Far guest", requestedLane: lane,
                                     clientNonce: clientNonce, credentialProof: proof)
        let helloEnvelope = try SessionEnvelope(lane: .control, kind: .hello, sequence: 0, sessionID: session, senderID: participant,
                                                payload: hello.encode())
        _ = SocketFrameIO.writeFrame(socket: socket, data: try SessionFrameSealer(credential: credential).seal(helloEnvelope, streamID: UUID()).encode())
        let welcome = try RelayWelcomePayload.decode(open(RelayLaneServer.readFrame(socket.fd, 1_048_576)).payload)
        let assignment = try welcome.verify(credential: credential, context: context, challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce, guide: GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guideID),
            nowMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000))
        return (assignment, socket)
    }

    static func connect(port: UInt16) throws -> ManagedSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw RelayLaneServer.EndOfStream() }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return ManagedSocket(fd: fd, generation: 0)
    }

    @Test func unassignedBridgeRefusesPeers() throws {
        let server = try RelayLaneServer(lane: .realtime, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub)
        defer { server.close() }
        let socket = try Self.connect(port: server.port)
        defer { socket.close() }
        #expect(throws: RelayLaneServer.EndOfStream.self) { try RelayLaneServer.readFrame(socket.fd, 65_536) }
    }

    @Test func assignedBridgeAdmitsMemberAndForwardsGuideFramesAndUpstream() throws {
        try assign(bridgeID, generation: 1)
        let forwarded = Faults()
        let server = try RelayLaneServer(lane: .control, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub, onUpstream: { forwarded.append($0.farParticipantID.uuidString) })
        defer { server.close() }
        let me = UUID()
        let (assignment, socket) = try join(server, lane: .control, participant: me)
        defer { socket.close() }
        #expect(assignment.bridgeID == bridgeID)
        // The cached assignment replays first.
        let replayed = try RelayLaneServer.readFrame(socket.fd, 1_048_576)
        #expect(try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guideID).verify(replayed).kind == .bridgeAssignment)
        let target = try frame(.targetSnapshot)
        hub.onUpstreamFrame(lane: .control, frame: target, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        #expect(try RelayLaneServer.readFrame(socket.fd, 1_048_576) == target)
        let status = try SessionEnvelope(lane: .control, kind: .audioStatus, sequence: 1, sessionID: session, senderID: me,
                                         payload: AudioReadinessPayload(status: .playing, revision: 1).encode())
        _ = SocketFrameIO.writeFrame(socket: socket, data: try SessionFrameSealer(credential: credential).seal(status, streamID: UUID()).encode())
        let deadline = Date().addingTimeInterval(5)
        while forwarded.values.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(forwarded.values == [me.uuidString], "W5: the island guest's status is carried to the guide")
        #expect(faults.values.isEmpty)
    }

    @Test func nonMemberAndStaleGenerationGetNoWelcome() throws {
        try assign(bridgeID, generation: 2)
        let server = try RelayLaneServer(lane: .control, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub)
        defer { server.close() }
        let outsider = try SessionCredential.derive(shortCode: "ZZZZ9999AB", sessionID: session)
        #expect(throws: (any Error).self) { _ = try join(server, lane: .control, generation: 2, with: outsider) }
        #expect(throws: (any Error).self) { _ = try join(server, lane: .control, generation: 1) }
    }

    @Test func assetLaneReplaysManifestAndServesHeldFiles() throws {
        try assign(bridgeID, generation: 1)
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = try TourPackManifestPayload(packID: UUID(), manifestVersion: 1, displayName: "Tour", assets: [
            TourAssetDescriptor(assetID: "slide", kind: .slide, sha256: hash, byteLength: UInt64(bytes.count), order: 0, mimeType: "image/jpeg")])
        let manifestFrame = try frame(.tourPackManifest, manifest.encode())
        hub.onUpstreamFrame(lane: .asset, frame: manifestFrame, receivedAtMilliseconds: 0, nowMilliseconds: 0)
        let server = try RelayLaneServer(lane: .asset, credential: credential, sessionID: session, guideID: guideID,
                                         bridgeID: bridgeID, hub: hub, assetFile: { $0 == hash ? url : nil })
        defer { server.close() }
        let me = UUID()
        let (_, socket) = try join(server, lane: .asset, participant: me)
        defer { socket.close() }
        #expect(try RelayLaneServer.readFrame(socket.fd, 1_048_576) == manifestFrame)
        let requestSealer = SessionFrameSealer(credential: credential), opener = SessionFrameOpener(credential: credential)
        var received = Data(); var request: UInt64 = 0
        while received.count < bytes.count {
            request += 1
            let ask = try SessionEnvelope(lane: .asset, kind: .assetRequest, sequence: request, sessionID: session, senderID: me,
                                          payload: AssetRequestPayload(sha256: hash, offset: UInt64(received.count)).encode())
            _ = SocketFrameIO.writeFrame(socket: socket, data: try requestSealer.seal(ask, streamID: UUID()).encode())
            guard case let .opened(envelope) = try opener.open(SealedSessionEnvelope.decode(RelayLaneServer.readFrame(socket.fd, 1_048_576))) else {
                Issue.record("duplicate chunk"); return
            }
            #expect(envelope.senderID == bridgeID)
            let chunk = try AssetChunkPayload.decode(envelope.payload)
            #expect(PeerAssetAcceptance.accepts(chunk, manifest: manifest))
            received.append(chunk.bytes)
        }
        #expect(received == bytes)
    }
}

/// Monotonic per-test guide sequence (the sealer requires increasing sequences per stream).
final class GuideSequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value += 1; return value } }
}
