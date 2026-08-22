import Darwin
import Foundation
import Observation
import os
import TourSessionCore

/// Local-LAN TCP transport.
///
/// Every connection starts with a GOH2 control-lane hello. Guide-to-guest audio is
/// carried in GOH2 realtime envelopes. The class name remains temporarily stable
/// while callers migrate away from the legacy transport naming.
@Observable
final class UDPAudioPlane: AudioPlane {
    private struct SessionConfiguration: Sendable {
        let sessionID: UUID
        let participantID: UUID
        let displayName: String
        let platform: ParticipantPlatform
        let credential: SessionCredential
    }

    private struct ClientConnection: Sendable {
        let fd: Int32
        let connectionID: String
        let participantID: UUID
    }

    private(set) var isActive = false
    var hostIP: String?

    private let port: UInt16 = 50000
    private let maximumFrameSize = 1_048_576
    private var configuration: SessionConfiguration?
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var connectedClients: [ClientConnection] = []
    private let sendQueue = DispatchQueue(label: "audio.tcp.send", qos: .userInteractive)
    private var recvTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    nonisolated(unsafe) private var onAudioCallback: (@Sendable (Data) -> Void)?
    nonisolated(unsafe) private var sessionEventHandler: (@Sendable (AudioSessionEvent) -> Void)?
    private var sendSequence: UInt64 = 0
    private var sentPacketCount = 0
    private var receivedPacketCount = 0

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        configuration = SessionConfiguration(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setSessionEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {
        sessionEventHandler = handler
    }

    // MARK: - Guide

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        guard let configuration, configuration.sessionID.uuidString == channelID.uppercased() else {
            Logger.audio.error("TCP: missing or mismatched GOH2 session configuration")
            return
        }

        stopSockets()
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            Logger.audio.error("TCP: socket failed: \(String(cString: strerror(errno)))")
            return
        }

        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Logger.audio.error("TCP: bind failed: \(String(cString: strerror(errno)))")
            close(serverFD)
            serverFD = -1
            return
        }
        guard Darwin.listen(serverFD, 64) == 0 else {
            Logger.audio.error("TCP: listen failed: \(String(cString: strerror(errno)))")
            close(serverFD)
            serverFD = -1
            return
        }

        isActive = true
        sendSequence = 0
        sentPacketCount = 0
        Logger.audio.info("TCP: GOH2 server listening on port \(self.port)")

        let listeningFD = serverFD
        acceptTask = Task { @concurrent [weak self] in
            while !Task.isCancelled {
                var clientAddress = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let acceptedFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(listeningFD, $0, &length)
                    }
                }
                guard acceptedFD >= 0 else { break }

                Task { @concurrent [weak self] in
                    guard let participant = Self.authenticateGuest(
                        fd: acceptedFD,
                        configuration: configuration
                    ) else {
                        close(acceptedFD)
                        return
                    }
                    let connectionID = UUID().uuidString
                    await self?.registerClient(
                        fd: acceptedFD,
                        connectionID: connectionID,
                        participantID: participant.participantID,
                        displayName: participant.displayName,
                        platform: participant.platform
                    )

                    var unexpectedByte: UInt8 = 0
                    _ = Darwin.recv(acceptedFD, &unexpectedByte, 1, 0)
                    await self?.removeClient(fd: acceptedFD)
                }
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard isActive, !connectedClients.isEmpty, let configuration else { return }

        let envelope: SessionEnvelope
        do {
            envelope = try SessionEnvelope(
                lane: .realtime,
                kind: .audioFrame,
                sequence: sendSequence,
                sessionID: configuration.sessionID,
                senderID: configuration.participantID,
                payload: data
            )
        } catch {
            Logger.audio.error("TCP: failed to encode GOH2 audio")
            return
        }
        sendSequence &+= 1
        let frame = envelope.encode()
        let clients = connectedClients

        sendQueue.async { [weak self] in
            guard let self else { return }
            self.sentPacketCount += 1
            if self.sentPacketCount == 1 {
                Logger.audio.info("TCP: sending first GOH2 audio frame to \(clients.count) client(s)")
            }
            let dead = clients.compactMap { client in
                Self.writeFrame(fd: client.fd, data: frame) ? nil : client.fd
            }
            guard !dead.isEmpty else { return }
            Task { @MainActor [weak self] in
                for fd in dead { self?.removeClient(fd: fd) }
            }
        }
    }

    // MARK: - Guest

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        onAudioCallback = onAudio
        guard let host = hostIP else {
            Logger.audio.error("TCP: no host IP to connect to")
            return
        }
        guard let configuration, configuration.sessionID.uuidString == channelID.uppercased() else {
            Logger.audio.error("TCP: missing or mismatched GOH2 session configuration")
            return
        }

        isActive = true
        receivedPacketCount = 0
        recvTask = Task { @concurrent [weak self] in
            Logger.audio.info("TCP: connecting to guide")
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                Logger.audio.error("TCP: socket failed: \(String(cString: strerror(errno)))")
                return
            }
            await MainActor.run { self?.clientFD = fd }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = (self?.port ?? 50000).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                Logger.audio.error("TCP: invalid guide address")
                close(fd)
                return
            }

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                Logger.audio.error("TCP: connect failed: \(String(cString: strerror(errno)))")
                close(fd)
                return
            }

            let guideID: UUID
            do {
                guideID = try Self.authenticateGuide(fd: fd, configuration: configuration)
            } catch {
                Logger.audio.error("TCP: authentication failed")
                close(fd)
                return
            }
            Logger.audio.info("TCP: authenticated GOH2 session joined")

            while !Task.isCancelled {
                guard let frame = Self.readFrame(fd: fd, maximumSize: self?.maximumFrameSize ?? 1_048_576) else {
                    break
                }
                do {
                    let envelope = try SessionEnvelope.decode(frame)
                    guard envelope.sessionID == configuration.sessionID,
                          envelope.senderID == guideID,
                          envelope.kind == .audioFrame,
                          envelope.lane == .realtime else {
                        Logger.audio.error("TCP: rejected unexpected GOH2 frame")
                        break
                    }
                    await MainActor.run {
                        guard let self else { return }
                        self.receivedPacketCount += 1
                        if self.receivedPacketCount == 1 {
                            Logger.audio.info("TCP: received first GOH2 audio frame")
                        }
                    }
                    self?.onAudioCallback?(envelope.payload)
                } catch {
                    Logger.audio.error("TCP: invalid GOH2 frame")
                    break
                }
            }
            close(fd)
            Logger.audio.info("TCP: disconnected")
        }
    }

    func stop() {
        isActive = false
        acceptTask?.cancel()
        recvTask?.cancel()
        acceptTask = nil
        recvTask = nil
        stopSockets()
        onAudioCallback = nil
        Logger.audio.info("TCP: stopped")
    }

    // MARK: - Membership

    private func registerClient(
        fd: Int32,
        connectionID: String,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform
    ) {
        if let existing = connectedClients.first(where: { $0.participantID == participantID }) {
            removeClient(fd: existing.fd)
        }
        connectedClients.append(ClientConnection(
            fd: fd,
            connectionID: connectionID,
            participantID: participantID
        ))
        sessionEventHandler?(.joined(ParticipantSession(
            participantID: participantID,
            connectionID: connectionID,
            displayName: displayName,
            role: .guest,
            platform: platform
        )))
        Logger.audio.info("TCP: validated guest session")
    }

    private func removeClient(fd: Int32) {
        guard let index = connectedClients.firstIndex(where: { $0.fd == fd }) else { return }
        let client = connectedClients.remove(at: index)
        close(client.fd)
        sessionEventHandler?(.disconnected(connectionID: client.connectionID))
    }

    // MARK: - Framing

    nonisolated private static func authenticateGuest(
        fd: Int32,
        configuration: SessionConfiguration
    ) -> (participantID: UUID, displayName: String, platform: ParticipantPlatform)? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        do {
            let challengeNonce = SessionAuthenticator.randomNonce()
            let challenge = try AuthChallengePayload(
                requestedLane: .realtime,
                challengeNonce: challengeNonce
            )
            let challengeEnvelope = try SessionEnvelope(
                lane: .control,
                kind: .authChallenge,
                sequence: 0,
                sessionID: configuration.sessionID,
                senderID: configuration.participantID,
                payload: challenge.encode()
            )
            guard writeFrame(fd: fd, data: challengeEnvelope.encode()),
                  let frame = readFrame(fd: fd, maximumSize: 65_536) else {
                Logger.audio.error("TCP: client did not complete authentication")
                return nil
            }
            let envelope = try SessionEnvelope.decode(frame)
            guard envelope.sessionID == configuration.sessionID,
                  envelope.kind == .hello,
                  envelope.lane == .control,
                  envelope.senderID != configuration.participantID else {
                Logger.audio.error("TCP: rejected hello for the wrong session or lane")
                return nil
            }
            let hello = try HelloPayload.decode(envelope.payload)
            guard hello.role == .guest, hello.requestedLane == .realtime else {
                Logger.audio.error("TCP: rejected non-guest hello")
                return nil
            }
            let expectedProof = try SessionAuthenticator.guestProof(
                credential: configuration.credential,
                sessionID: configuration.sessionID,
                guideID: configuration.participantID,
                participantID: envelope.senderID,
                requestedLane: .realtime,
                challengeNonce: challengeNonce,
                clientNonce: hello.clientNonce,
                role: hello.role,
                platform: hello.platform,
                capabilities: hello.capabilities,
                displayName: hello.displayName
            )
            guard SessionAuthenticator.securelyMatches(expectedProof, hello.credentialProof) else {
                Logger.audio.error("TCP: rejected tour-code proof")
                return nil
            }
            let guideNonce = SessionAuthenticator.randomNonce()
            let guideProof = try SessionAuthenticator.guideProof(
                credential: configuration.credential,
                sessionID: configuration.sessionID,
                guideID: configuration.participantID,
                participantID: envelope.senderID,
                requestedLane: .realtime,
                challengeNonce: challengeNonce,
                clientNonce: hello.clientNonce,
                guideNonce: guideNonce
            )
            let welcomePayload = try WelcomePayload(
                requestedLane: .realtime,
                guideNonce: guideNonce,
                credentialProof: guideProof
            )
            let welcome = try SessionEnvelope(
                lane: .control,
                kind: .welcome,
                sequence: 0,
                sessionID: configuration.sessionID,
                senderID: configuration.participantID,
                payload: welcomePayload.encode()
            )
            guard writeFrame(fd: fd, data: welcome.encode()) else { return nil }
            return (envelope.senderID, hello.displayName, hello.platform)
        } catch {
            Logger.audio.error("TCP: rejected malformed GOH2 hello")
            return nil
        }
    }

    nonisolated private static func authenticateGuide(
        fd: Int32,
        configuration: SessionConfiguration
    ) throws -> UUID {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        guard let challengeFrame = readFrame(fd: fd, maximumSize: 65_536) else {
            throw AudioAuthenticationError.incompleteHandshake
        }
        let challengeEnvelope = try SessionEnvelope.decode(challengeFrame)
        guard challengeEnvelope.sessionID == configuration.sessionID,
              challengeEnvelope.kind == .authChallenge,
              challengeEnvelope.lane == .control,
              challengeEnvelope.senderID != configuration.participantID else {
            throw AudioAuthenticationError.invalidChallenge
        }
        let challenge = try AuthChallengePayload.decode(challengeEnvelope.payload)
        guard challenge.requestedLane == .realtime else { throw AudioAuthenticationError.invalidChallenge }
        let clientNonce = SessionAuthenticator.randomNonce()
        let proof = try SessionAuthenticator.guestProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: configuration.participantID,
            requestedLane: .realtime,
            challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce,
            role: .guest,
            platform: configuration.platform,
            capabilities: 0,
            displayName: configuration.displayName
        )
        let hello = try HelloPayload(
            role: .guest,
            platform: configuration.platform,
            capabilities: 0,
            displayName: configuration.displayName,
            requestedLane: .realtime,
            clientNonce: clientNonce,
            credentialProof: proof
        )
        let helloEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .hello,
            sequence: 0,
            sessionID: configuration.sessionID,
            senderID: configuration.participantID,
            payload: hello.encode()
        )
        guard writeFrame(fd: fd, data: helloEnvelope.encode()),
              let welcomeFrame = readFrame(fd: fd, maximumSize: 65_536) else {
            throw AudioAuthenticationError.incompleteHandshake
        }
        let welcomeEnvelope = try SessionEnvelope.decode(welcomeFrame)
        guard welcomeEnvelope.sessionID == configuration.sessionID,
              welcomeEnvelope.kind == .welcome,
              welcomeEnvelope.lane == .control,
              welcomeEnvelope.senderID == challengeEnvelope.senderID else {
            throw AudioAuthenticationError.invalidWelcome
        }
        let welcome = try WelcomePayload.decode(welcomeEnvelope.payload)
        guard welcome.requestedLane == .realtime else { throw AudioAuthenticationError.invalidWelcome }
        let expectedProof = try SessionAuthenticator.guideProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: configuration.participantID,
            requestedLane: .realtime,
            challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce,
            guideNonce: welcome.guideNonce
        )
        guard SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof) else {
            throw AudioAuthenticationError.invalidWelcome
        }
        return challengeEnvelope.senderID
    }

    nonisolated private enum AudioAuthenticationError: LocalizedError {
        case incompleteHandshake
        case invalidChallenge
        case invalidWelcome

        var errorDescription: String? {
            switch self {
            case .incompleteHandshake: "guide did not complete authentication"
            case .invalidChallenge: "invalid guide authentication challenge"
            case .invalidWelcome: "guide tour-code proof was rejected"
            }
        }
    }

    nonisolated private static func writeFrame(fd: Int32, data: Data) -> Bool {
        guard data.count <= Int(UInt32.max) else { return false }
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        return writeAll(fd: fd, data: header) && writeAll(fd: fd, data: data)
    }

    nonisolated private static func writeAll(fd: Int32, data: Data) -> Bool {
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

    nonisolated private static func readFrame(fd: Int32, maximumSize: Int) -> Data? {
        var header = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: fd, buffer: &header, count: 4) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumSize) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        guard readExact(fd: fd, buffer: &bytes, count: bytes.count) else { return nil }
        return Data(bytes)
    }

    nonisolated private static func readExact(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
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

    private func stopSockets() {
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }
        for client in connectedClients { close(client.fd) }
        connectedClients.removeAll()
    }
}
