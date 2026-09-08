import Darwin
import Foundation
import TourSessionCore

/// A guest that speaks the GOH2 handshake but is otherwise inert: it never reads unless asked and
/// stamps whatever sender ID the test gives it. The production transport can emulate neither (it
/// always reads, and always stamps its own participant ID), which the FND-12 stalled-peer and
/// forged-sender tests need. `authenticate` is a port of
/// `LocalAuthenticatedSessionTransport.authenticateGuide`.
///
/// Every method blocks. Call them from a `Task { @concurrent }` and await it, never on the main
/// actor: the guide hops to the main actor to register the client, so a blocked main actor
/// deadlocks the handshake.
nonisolated final class RawGuestClient: @unchecked Sendable {
    enum ClientError: Error {
        case socket(String)
        case connect(String)
        case handshake(String)
        case write
    }

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16, receiveBufferBytes: Int32? = nil) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socket(String(cString: strerror(errno))) }
        if var bytes = receiveBufferBytes {
            // Before connect, so the window is advertised at SYN time.
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ClientError.connect(message)
        }
        self.fd = fd
    }

    /// Completes the sealed challenge/hello/welcome handshake and returns the guide's sender ID.
    func authenticate(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
        lane: SessionLane,
        guideVerifier: GuideFrameVerifier? = nil,
        capabilities: UInt32 = 0
    ) throws -> UUID {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        let guideOpener = SessionFrameOpener(credential: credential)
        guard let challengeFrame = readFrame() else {
            throw ClientError.handshake("no authentication challenge")
        }
        guard let challengeEnvelope = try Self.openFrame(challengeFrame, using: guideOpener, verifier: guideVerifier) else {
            throw ClientError.handshake("duplicate authentication challenge")
        }
        guard challengeEnvelope.sessionID == sessionID,
              challengeEnvelope.kind == .authChallenge,
              challengeEnvelope.lane == .control,
              challengeEnvelope.senderID != participantID else {
            throw ClientError.handshake("unexpected authentication challenge")
        }
        let challenge = try AuthChallengePayload.decode(challengeEnvelope.payload)
        guard challenge.requestedLane == lane else {
            throw ClientError.handshake("authentication challenge used the wrong lane")
        }
        let clientNonce = SessionAuthenticator.randomNonce()
        let proof = try SessionAuthenticator.guestProof(
            credential: credential,
            sessionID: sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: participantID,
            requestedLane: lane,
            challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce,
            role: .guest,
            platform: platform,
            capabilities: capabilities,
            displayName: displayName
        )
        let hello = try HelloPayload(
            role: .guest,
            platform: platform,
            capabilities: capabilities,
            displayName: displayName,
            requestedLane: lane,
            clientNonce: clientNonce,
            credentialProof: proof
        )
        let helloEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .hello,
            sequence: 0,
            sessionID: sessionID,
            senderID: participantID,
            payload: hello.encode()
        )
        try send(helloEnvelope, sealer: SessionFrameSealer(credential: credential), streamID: UUID())
        guard let welcomeFrame = readFrame() else {
            throw ClientError.handshake("no welcome")
        }
        guard let welcomeEnvelope = try Self.openFrame(welcomeFrame, using: guideOpener, verifier: guideVerifier) else {
            throw ClientError.handshake("duplicate welcome")
        }
        guard welcomeEnvelope.sessionID == sessionID,
              welcomeEnvelope.kind == .welcome,
              welcomeEnvelope.lane == .control,
              welcomeEnvelope.senderID == challengeEnvelope.senderID else {
            throw ClientError.handshake("unexpected welcome")
        }
        let welcome = try WelcomePayload.decode(welcomeEnvelope.payload)
        guard welcome.requestedLane == lane else {
            throw ClientError.handshake("welcome used the wrong lane")
        }
        let expectedProof = try SessionAuthenticator.guideProof(
            credential: credential,
            sessionID: sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: participantID,
            requestedLane: lane,
            challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce,
            guideNonce: welcome.guideNonce
        )
        guard SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof) else {
            throw ClientError.handshake("guide credential proof was rejected")
        }
        return challengeEnvelope.senderID
    }

    /// Seals and writes one length-prefixed frame exactly as the production writer does.
    func send(_ envelope: SessionEnvelope, sealer: SessionFrameSealer, streamID: UUID) throws {
        let data = try sealer.seal(envelope, streamID: streamID).encode()
        var length = UInt32(data.count).bigEndian
        let frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
        guard writeAll(frame) else { throw ClientError.write }
    }

    /// Blocking read of one length-prefixed frame; nil once the guide closes the socket.
    func readFrame(maximumSize: Int = 1_048_576) -> Data? {
        var header = [UInt8](repeating: 0, count: 4)
        guard readExact(buffer: &header, count: header.count) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumSize) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        guard readExact(buffer: &bytes, count: bytes.count) else { return nil }
        return Data(bytes)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, MSG_NOSIGNAL)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func readExact(buffer: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received <= 0 { return false }
            offset += received
        }
        return true
    }

    private static func openFrame(_ frame: Data, using opener: SessionFrameOpener, verifier: GuideFrameVerifier?) throws -> SessionEnvelope? {
        let sealed: SealedSessionEnvelope
        if let verifier { sealed = try verifier.verify(frame) }
        else { sealed = try SealedSessionEnvelope.decode(frame) }
        switch try opener.open(sealed) {
        case let .opened(envelope):
            return envelope
        case .duplicate:
            return nil
        }
    }
}
