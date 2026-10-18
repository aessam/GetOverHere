import Darwin
import Foundation
import os
import TourSessionCore

/**
 The bridge's island listener for one lane (ADR-081 P4, ADR-083; mirrors Android `RelayLaneServer`). An island peer
 connects through the island advertiser, the bridge runs the relay lane handshake (its own challenge, the peer's relay
 proof, a `RelayWelcomePayload` carrying the guide-signed `bridgeAssignment`), then:
 - realtime/control: the peer is attached to `RelayHub` and receives verified guide frames unchanged; its own control
   audio status and leave go to the guide as W5 records (advisory, DSCN-3);
 - asset: the guide-signed manifest is replayed, and the bridge serves requested chunks of files it holds,
   bridge-sealed through the peer's single bounded writer. Chunks never pass through `RelayHub`.
 Peers are refused until the guide has assigned this bridge. Admission is not handled here.
 */
nonisolated final class RelayLaneServer: @unchecked Sendable {
    enum ServerError: Error { case listenFailed(String) }

    static let helloMaximum = 65_536
    static let chunkSize = 60 * 1_024
    private static let logger = Logger(subsystem: "com.aens.GetOverHere", category: "RelayLaneServer")

    let lane: SessionLane
    let port: UInt16
    private let credential: SessionCredential
    private let sessionID: UUID
    private let guideID: UUID
    private let bridgeID: UUID
    private let hub: RelayHub
    private let assetFile: @Sendable (String) -> URL?
    private let onUpstream: @Sendable (RelayUpstreamRecord) -> Void
    private let listener: ManagedSocket
    private let lock = NSLock()
    private var upstreamCount = 0

    /// Advisory frames island peers sent upstream.
    var upstreamFrames: Int { lock.withLock { upstreamCount } }

    init(lane: SessionLane, credential: SessionCredential, sessionID: UUID, guideID: UUID, bridgeID: UUID, hub: RelayHub,
         assetFile: @escaping @Sendable (String) -> URL? = { _ in nil },
         onUpstream: @escaping @Sendable (RelayUpstreamRecord) -> Void = { _ in }) throws {
        self.lane = lane
        self.credential = credential
        self.sessionID = sessionID
        self.guideID = guideID
        self.bridgeID = bridgeID
        self.hub = hub
        self.assetFile = assetFile
        self.onUpstream = onUpstream
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.listenFailed("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ServerError.listenFailed("bind/listen: \(message)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = ManagedSocket(fd: fd, generation: 0)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func close() {
        listener.cancel()
        listener.close()
    }

    private func acceptLoop() {
        while !listener.isCancelled {
            let fd = Darwin.accept(listener.fd, nil, nil)
            guard fd >= 0 else {
                if !listener.isCancelled { Self.logger.error("Relay \(String(describing: self.lane)) accept failed: \(String(cString: strerror(errno)))") }
                return
            }
            Thread.detachNewThread { [self] in serve(ManagedSocket(fd: fd, generation: 0)) }
        }
    }

    private func serve(_ socket: ManagedSocket) {
        var yes: Int32 = 1
        setsockopt(socket.fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        Self.setReceiveTimeout(fd: socket.fd, seconds: 5)
        do {
            guard let (assignmentFrame, assignment) = hub.assigned else {
                throw RelayProtocolError.assignmentNamesAnotherHost // not assigned by the guide yet
            }
            let sealer = SessionFrameSealer(credential: credential)
            let stream = UUID()
            let peer = try handshake(socket, sealer: sealer, stream: stream, assignmentFrame: assignmentFrame,
                                     generation: assignment.generation)
            Self.setReceiveTimeout(fd: socket.fd, seconds: 0)
            let writer = SocketChildWriter(socket: socket, lane: lane)
            hub.attach(lane: lane, writer: writer)
            defer {
                hub.detach(lane: lane, writer: writer)
                writer.close()
            }
            switch lane {
            case .realtime, .control: try consumeUpstream(socket, peer: peer)
            case .asset: try serveAssets(socket, sealer: sealer, stream: stream, peer: peer, writer: writer)
            }
        } catch {
            if !(error is EndOfStream) {
                Self.logger.error("Relay \(String(describing: self.lane)) peer ended: \(String(describing: error))")
            }
            socket.cancel()
            socket.close()
        }
    }

    /// Bridge side of ADR-083; returns the authenticated peer's participant ID.
    private func handshake(_ socket: ManagedSocket, sealer: SessionFrameSealer, stream: UUID, assignmentFrame: Data,
                           generation: UInt64) throws -> UUID {
        let challengeNonce = SessionAuthenticator.randomNonce()
        try write(socket, sealer.seal(envelope(.authChallenge, 0,
            AuthChallengePayload(requestedLane: lane, challengeNonce: challengeNonce).encode()), streamID: stream).encode())
        let opener = SessionFrameOpener(credential: credential)
        guard case let .opened(hello) = try opener.open(SealedSessionEnvelope.decode(try Self.readFrame(socket.fd, Self.helloMaximum))) else {
            throw RelayProtocolError.relayProofMismatch
        }
        let payload = try HelloPayload.decode(hello.payload)
        guard hello.sessionID == sessionID, hello.kind == .hello, hello.senderID != bridgeID, hello.senderID != guideID,
              payload.role == .guest, payload.requestedLane == lane else { throw RelayProtocolError.wrongLane }
        let context = RelayLaneContext(sessionID: sessionID, guideID: guideID,
                                       host: RelayHostAdvert(hostID: bridgeID, bridgeGeneration: generation),
                                       participantID: hello.senderID, lane: lane)
        let expected = try RelayLaneAuthenticator.guestProof(credential: credential, context: context,
            challengeNonce: challengeNonce, clientNonce: payload.clientNonce, role: payload.role, platform: payload.platform,
            capabilities: payload.capabilities, displayName: payload.displayName)
        guard SessionAuthenticator.securelyMatches(expected, payload.credentialProof) else { throw RelayProtocolError.relayProofMismatch }
        let bridgeNonce = SessionAuthenticator.randomNonce()
        let proof = try RelayLaneAuthenticator.bridgeProof(credential: credential, context: context,
            challengeNonce: challengeNonce, clientNonce: payload.clientNonce, bridgeNonce: bridgeNonce)
        let welcome = try RelayWelcomePayload(lane: lane, bridgeNonce: bridgeNonce, proof: proof, assignmentFrame: assignmentFrame)
        try write(socket, sealer.seal(envelope(.welcome, 1, welcome.encode()), streamID: stream).encode())
        return hello.senderID
    }

    /// Island peers' own frames on realtime/control; control audio status and leave go to the guide as W5 records.
    private func consumeUpstream(_ socket: ManagedSocket, peer: UUID) throws {
        let opener = SessionFrameOpener(credential: credential)
        while !socket.isCancelled {
            let raw = try Self.readFrame(socket.fd, Self.helloMaximum)
            guard case let .opened(envelope) = try opener.open(SealedSessionEnvelope.decode(raw)) else { continue }
            guard envelope.sessionID == sessionID, envelope.senderID == peer else { throw RelayProtocolError.wrongLane }
            lock.withLock { upstreamCount += 1 }
            if lane == .control, envelope.kind == .audioStatus || envelope.kind == .leave {
                do { onUpstream(try RelayUpstreamRecord(farParticipantID: peer, lane: lane, frame: raw)) } catch {
                    Self.logger.error("Relay upstream forward failed: \(String(describing: error))")
                }
            }
            if envelope.kind == .leave { return }
        }
    }

    private func serveAssets(_ socket: ManagedSocket, sealer: SessionFrameSealer, stream: UUID, peer: UUID,
                             writer: SocketChildWriter) throws {
        let opener = SessionFrameOpener(credential: credential)
        var sequence: UInt64 = 1
        while !socket.isCancelled {
            guard case let .opened(request) = try opener.open(SealedSessionEnvelope.decode(try Self.readFrame(socket.fd, Self.helloMaximum)))
            else { continue }
            guard request.senderID == peer else { throw RelayProtocolError.wrongLane }
            if request.kind == .assetStatus {
                lock.withLock { upstreamCount += 1 } // advisory (DSCN-3)
                continue
            }
            guard request.kind == .assetRequest else { throw RelayProtocolError.wrongLane }
            let wanted = try AssetRequestPayload.decode(request.payload)
            guard let url = assetFile(wanted.sha256) else { throw AssetMiss(sha256: wanted.sha256) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            guard wanted.offset < length else { throw AssetMiss(sha256: wanted.sha256) }
            try handle.seek(toOffset: wanted.offset)
            let bytes = try handle.read(upToCount: Int(min(UInt64(Self.chunkSize), length - wanted.offset))) ?? Data()
            sequence += 1
            let chunk = try AssetChunkPayload(sha256: wanted.sha256, offset: wanted.offset, totalLength: length, bytes: bytes)
            // One writer per socket: chunks and relayed manifests never interleave mid-frame.
            guard writer.enqueue(try sealer.seal(envelope(.assetChunk, sequence, chunk.encode()), streamID: stream).encode()) else {
                throw EndOfStream()
            }
        }
    }

    private func envelope(_ kind: SessionMessageKind, _ sequence: UInt64, _ payload: Data) throws -> SessionEnvelope {
        try SessionEnvelope(lane: kind.requiredLane, kind: kind, sequence: sequence, sessionID: sessionID,
                            senderID: bridgeID, payload: payload)
    }

    private func write(_ socket: ManagedSocket, _ data: Data) throws {
        guard SocketFrameIO.writeFrame(socket: socket, data: data) else { throw EndOfStream() }
    }

    struct EndOfStream: Error {}
    /// The bridge does not hold this hash (yet); the island peer's asset lane ends and it retries (P3).
    struct AssetMiss: Error { let sha256: String }

    static func readFrame(_ fd: Int32, _ maximum: Int) throws -> Data {
        let header = try readExact(fd, 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximum) else { throw RelayProtocolError.wrongLane }
        return try readExact(fd, Int(length))
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard received > 0 else { throw EndOfStream() }
            offset += received
        }
        return Data(bytes)
    }

    private static func setReceiveTimeout(fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// One island peer's outbound side (ADR-039): a bounded writer drained on its own queue with a send timeout, so a
/// stalled peer never blocks `RelayHub` (which enqueues under its lock) or other peers.
nonisolated final class SocketChildWriter: RelayChildWriter, @unchecked Sendable {
    private let writer: BoundedSocketFrameWriter
    private let failure = OSAllocatedUnfairLock(initialState: false)

    init(socket: ManagedSocket, lane: SessionLane) {
        let failed = failure
        let capacity = switch lane { case .control: 64; case .asset: 16; case .realtime: 8 }
        writer = BoundedSocketFrameWriter(
            socket: socket,
            label: "relay-\(lane)-peer-writer",
            capacity: capacity,
            overflowPolicy: .disconnect,
            sendTimeoutMilliseconds: 2_000
        ) { _, _ in failed.withLock { $0 = true } }
    }

    func enqueue(_ frame: Data) -> Bool {
        guard !failure.withLock({ $0 }) else { return false }
        writer.enqueue(frame)
        return !failure.withLock { $0 }
    }

    func close() {
        failure.withLock { $0 = true }
        writer.stop()
    }
}
