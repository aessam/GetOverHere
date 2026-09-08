import Darwin
import Foundation
import os
import TourSessionCore

/// Reliable GOH2 control lane carried on a socket independent from live audio.
private final class LocalAuthenticatedSessionTransport {
    private struct Configuration: Sendable {
        let sessionID: UUID
        let participantID: UUID
        let displayName: String
        let platform: ParticipantPlatform
        let credential: SessionCredential
    }

    private struct ClientConnection: Sendable {
        let writer: BoundedSocketFrameWriter
        let participant: ParticipantSession
    }

    private let port: UInt16
    private let applicationLane: SessionLane
    private let maximumFrameSize = 1_048_576
    private let acceptQueue = DispatchQueue(label: "session.data.accept", qos: .userInitiated)
    private let guestQueue = DispatchQueue(label: "session.data.guest", qos: .userInitiated)
    /// Off-actor wait for the terminal leave flush (FND-8).
    private let terminalFlushQueue = DispatchQueue(label: "session.data.terminal", qos: .userInitiated)
    /// Accepted-but-unauthenticated connections held at once (RSK-1, ADR-047).
    nonisolated private static let maximumPendingHandshakes = 32
    private let handshakeSlots = HandshakeSlots(limit: LocalAuthenticatedSessionTransport.maximumPendingHandshakes)
    private var configuration: Configuration?
    private var authentication: SessionGuideAuthentication
    private var eventHandler: (@Sendable (SessionControlEvent) -> Void)?
    private var serverFD: Int32 = -1
    private var guestSocket: ManagedSocket?
    private var guestWriter: BoundedSocketFrameWriter?
    private var clients: [ClientConnection] = []
    private var runGeneration: UInt64 = 0
    private var sendSequence: UInt64 = 1
    private var outboundSealer: SessionFrameSealer?
    private var outboundStreamID = UUID()

    private(set) var isActive = false
    var hostIP: String?

    init(port: UInt16, applicationLane: SessionLane, authentication: SessionGuideAuthentication) {
        self.port = port
        self.applicationLane = applicationLane
        self.authentication = authentication
    }

    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication) {
        stop()
        self.authentication = authentication
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        configuration = Configuration(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        eventHandler = handler
    }

    /// Synchronous and throwing (FND-2): the guide commits state only after every lane is listening.
    func startGuide() throws {
        guard let configuration else {
            throw ControlTransportError.notConfigured
        }
        let authentication = self.authentication
        try authentication.requireGuide(sessionID: configuration.sessionID, guideID: configuration.participantID)

        stop()
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw ControlTransportError.socketFailed(Self.socketError("Session: socket failed"))
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
        guard bindResult == 0, Darwin.listen(serverFD, 64) == 0 else {
            let message = Self.socketError("Session: bind/listen failed")
            close(serverFD)
            serverFD = -1
            throw ControlTransportError.bindFailed(message)
        }

        isActive = true
        sendSequence = 1
        outboundSealer = SessionFrameSealer(credential: configuration.credential)
        outboundStreamID = UUID()
        let inboundOpener = SessionFrameOpener(credential: configuration.credential)
        let listeningFD = serverFD
        let expectedApplicationLane = applicationLane
        let handshakeSlots = self.handshakeSlots
        let participantSlots = SessionParticipantSlots()
        runGeneration &+= 1
        let generation = runGeneration

        acceptQueue.async { [weak self] in
            while true {
                var clientAddress = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let acceptedFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(listeningFD, $0, &length)
                    }
                }
                guard acceptedFD >= 0 else { break }
                guard handshakeSlots.tryAcquire() else {
                    Logger.transport.error("Session: pending handshake bound reached; closing connection")
                    close(acceptedFD)
                    continue
                }
                Self.setNoDelay(fd: acceptedFD)
                let socket = ManagedSocket(fd: acceptedFD, generation: generation)
                let connectionQueue = DispatchQueue(
                    label: "session.data.client.\(UUID().uuidString)",
                    qos: .userInitiated
                )
                connectionQueue.async { [weak self] in
                    let connectionToken = UUID()
                    defer { participantSlots.release(connectionToken) }
                    let hello: (participantID: UUID, displayName: String, platform: ParticipantPlatform)
                    // The slot is held only while the handshake is pending: released on return or throw.
                    let outcome = Result {
                        try Self.authenticateGuest(
                            fd: acceptedFD,
                            configuration: configuration,
                            requestedLane: expectedApplicationLane,
                            authentication: authentication,
                            participantSlots: participantSlots,
                            connectionID: connectionToken
                        )
                    }
                    handshakeSlots.release()
                    switch outcome {
                    case let .success(value):
                        hello = value
                    case .failure(SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor)):
                        Task { @MainActor [weak self] in
                            self?.emit(.versionMismatch(
                                remoteMajor: remoteMajor,
                                localMajor: localMajor
                            ), generation: generation)
                        }
                        socket.close()
                        return
                    case let .failure(error):
                        fputs("Session: invalid guest hello (\(String(describing: type(of: error))))\n", stderr)
                        socket.close()
                        return
                    }

                    let connectionID = connectionToken.uuidString
                    let participant = ParticipantSession(
                        participantID: hello.participantID,
                        connectionID: connectionID,
                        displayName: hello.displayName,
                        role: .guest,
                        platform: hello.platform
                    )
                    let writer = BoundedSocketFrameWriter(
                        socket: socket,
                        label: "session.data.writer.\(connectionID)",
                        capacity: expectedApplicationLane == .control ? 64 : 8,
                        overflowPolicy: .disconnect,
                        sendTimeoutMilliseconds: 2_000
                    ) { [weak self] _, _ in
                        Task { @MainActor [weak self] in
                            self?.removeClient(socket: socket)
                        }
                    }
                    let registration = DispatchSemaphore(value: 0)
                    Task { @MainActor [weak self] in
                        self?.registerClient(writer: writer, participant: participant, generation: generation)
                        registration.signal()
                    }
                    registration.wait()
                    guard !socket.isCancelled else { return }

                    while let frame = Self.readFrame(fd: acceptedFD, maximumSize: 1_048_576) {
                        do {
                            guard let envelope = try Self.openFrame(frame, using: inboundOpener) else {
                                continue
                            }
                            guard envelope.sessionID == configuration.sessionID,
                                  envelope.senderID == participant.participantID,
                                  envelope.lane == expectedApplicationLane,
                                  envelope.kind != .hello,
                                  envelope.kind != .authChallenge,
                                  envelope.kind != .welcome else {
                                break
                            }
                            Task { @MainActor [weak self] in
                                self?.emitGuest(.envelopeReceived(envelope), socket: socket)
                            }
                            if envelope.kind == .leave { break }
                        } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                            Task { @MainActor [weak self] in
                                self?.emit(.versionMismatch(
                                    remoteMajor: remoteMajor,
                                    localMajor: localMajor
                                ), generation: generation)
                            }
                            break
                        } catch {
                            Task { @MainActor [weak self] in
                                self?.emit(.failed("Session: invalid guest envelope: \(error.localizedDescription)"), generation: generation)
                            }
                            break
                        }
                    }
                    writer.stop()
                    Task { @MainActor [weak self] in
                        self?.removeClient(socket: socket)
                    }
                }
            }
        }
    }

    func startGuest() {
        guard let configuration else {
            emit(.failed("Session: session is not configured"))
            return
        }
        let authentication = self.authentication
        do { try authentication.requireGuest() }
        catch {
            emit(.failed(error.localizedDescription))
            return
        }
        guard let hostIP else {
            emit(.failed("Session: guide host IP is missing"))
            return
        }

        stop()
        isActive = true
        sendSequence = 1
        outboundSealer = SessionFrameSealer(credential: configuration.credential)
        outboundStreamID = UUID()
        let inboundOpener = SessionFrameOpener(credential: configuration.credential)
        let controlPort = port
        let maximumFrameSize = maximumFrameSize
        let expectedApplicationLane = applicationLane
        runGeneration &+= 1
        let generation = runGeneration

        guestQueue.async { [weak self] in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                Task { @MainActor [weak self] in
                    self?.emit(.failed(Self.socketError("Session: socket failed")), generation: generation)
                }
                return
            }
            let socket = ManagedSocket(fd: fd, generation: generation)
            Self.setNoDelay(fd: fd)
            let registration = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                self?.setGuestSocket(socket, generation: generation)
                registration.signal()
            }
            registration.wait()
            guard !socket.isCancelled else {
                socket.close()
                return
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = controlPort.bigEndian
            guard inet_pton(AF_INET, hostIP, &address.sin_addr) == 1 else {
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                    self?.emit(.failed("Session: invalid guide host IP \(hostIP)"), generation: generation)
                }
                return
            }
            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                let message = Self.socketError("Session: connect failed")
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                    self?.emit(.failed(message), generation: generation)
                }
                return
            }

            Self.setReceiveTimeout(fd: fd, seconds: 5)
            let guideID: UUID
            do {
                guideID = try Self.authenticateGuide(
                    fd: fd,
                    configuration: configuration,
                    requestedLane: expectedApplicationLane,
                    maximumFrameSize: maximumFrameSize,
                    authentication: authentication
                )
            } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                    self?.emit(.versionMismatch(
                        remoteMajor: remoteMajor,
                        localMajor: localMajor
                    ), generation: generation)
                }
                return
            } catch ControlTransportError.guideIdentityRejected {
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                    self?.emit(.credentialRejected("Session: the admitted guide identity could not be verified"), generation: generation)
                }
                return
            } catch ControlTransportError.credentialRejected {
                // A wrong tour code is terminal and never retried (FND-8, DSCN-26).
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                    self?.emit(.credentialRejected("Session: the tour code was rejected by the guide"), generation: generation)
                }
                return
            } catch {
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                    self?.emit(.failed("Session: invalid welcome: \(error.localizedDescription)"), generation: generation)
                }
                return
            }

            Self.setReceiveTimeout(fd: fd, seconds: 0)
            let writer = BoundedSocketFrameWriter(
                socket: socket,
                label: "session.data.guest.writer.\(generation)",
                capacity: expectedApplicationLane == .control ? 64 : 8,
                overflowPolicy: .disconnect,
                sendTimeoutMilliseconds: 2_000
            ) { [weak self] _, failedGeneration in
                Task { @MainActor [weak self] in
                    self?.handleGuestWriterFailure(generation: failedGeneration)
                }
            }
            let writerRegistration = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                self?.setGuestWriter(writer, generation: generation)
                self?.emit(.connected, generation: generation)
                writerRegistration.signal()
            }
            writerRegistration.wait()
            guard !socket.isCancelled else { return }

            while let frame = Self.readFrame(fd: fd, maximumSize: maximumFrameSize) {
                do {
                    guard let envelope = try Self.openGuideFrame(frame, using: inboundOpener, authentication: authentication) else {
                        continue
                    }
                    guard envelope.sessionID == configuration.sessionID,
                          envelope.senderID == guideID,
                          envelope.lane == expectedApplicationLane,
                          envelope.kind != .hello,
                          envelope.kind != .authChallenge,
                          envelope.kind != .welcome else {
                        break
                    }
                    Task { @MainActor [weak self] in self?.emit(.envelopeReceived(envelope), generation: generation) }
                    if envelope.kind == .leave { break }
                } catch is GuideSignatureError {
                    Task { @MainActor [weak self] in
                        self?.emit(.credentialRejected("Session: guide frame signature verification failed"), generation: generation)
                    }
                    break
                } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                    Task { @MainActor [weak self] in
                        self?.emit(.versionMismatch(
                            remoteMajor: remoteMajor,
                            localMajor: localMajor
                        ), generation: generation)
                    }
                    break
                } catch {
                    Task { @MainActor [weak self] in
                        self?.emit(.failed("Session: invalid guide envelope: \(error.localizedDescription)"), generation: generation)
                    }
                    break
                }
            }

            writer.stop()
            Task { @MainActor [weak self] in
                let wasActive = self?.clearGuestSocket(socket, generation: generation) ?? false
                if wasActive { self?.emit(.disconnected, generation: generation) }
            }
        }
    }

    /// Synchronous send. A `.leave` blocks the caller for up to the 2 s delivery deadline and is
    /// reserved for the process-termination path; product code ends a tour through `sendLeave()`.
    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        guard let outbound = sealedOutboundFrame(kind: kind, payload: payload, to: participantID) else { return }
        if kind == .leave {
            let deliveries = outbound.destinations.compactMap { $0.enqueue(outbound.frame, trackDelivery: true) }
            let deadline = DispatchTime.now() + .seconds(2)
            if deliveries.contains(where: { !$0.wait(timeout: deadline) }) {
                emit(.failed("Session: terminal send did not complete before timeout"))
            }
        } else {
            outbound.destinations.forEach { $0.enqueue(outbound.frame) }
        }
    }

    /// Enqueues one authenticated leave to every connected peer and waits off the main actor for
    /// delivery or the 2 s deadline (FND-8): End Tour no longer blocks the main thread.
    func sendLeave() async {
        guard let outbound = sealedOutboundFrame(kind: .leave, payload: Data(), to: nil) else { return }
        let generation = runGeneration
        let deliveries = outbound.destinations.compactMap { $0.enqueue(outbound.frame, trackDelivery: true) }
        guard !deliveries.isEmpty else { return }
        let deadline = DispatchTime.now() + .seconds(2)
        let flushQueue = terminalFlushQueue
        let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            flushQueue.async {
                continuation.resume(returning: deliveries.allSatisfy { $0.wait(timeout: deadline) })
            }
        }
        if !delivered, generation == runGeneration {
            emit(.failed("Session: terminal send did not complete before timeout"))
        }
    }

    /// Seals one outbound frame and selects its writers; emits the failure and returns nil otherwise.
    private func sealedOutboundFrame(
        kind: SessionMessageKind,
        payload: Data,
        to participantID: UUID?
    ) -> (frame: Data, destinations: [BoundedSocketFrameWriter])? {
        guard kind.requiredLane == applicationLane,
              kind != .hello,
              kind != .authChallenge,
              kind != .welcome else {
            emit(.failed("Session: \(kind) is not valid for the \(applicationLane) lane"))
            return nil
        }
        guard isActive, let configuration else {
            emit(.failed("Session: transport is not active"))
            return nil
        }

        let frame: Data
        do {
            let envelope = try SessionEnvelope(
                lane: applicationLane,
                kind: kind,
                sequence: sendSequence,
                sessionID: configuration.sessionID,
                senderID: configuration.participantID,
                payload: payload
            )
            guard let outboundSealer else {
                emit(.failed("Session: frame encryption is not configured"))
                return nil
            }
            let sealed = try outboundSealer.seal(envelope, streamID: outboundStreamID)
            frame = serverFD >= 0 ? try authentication.encodeGuideFrame(sealed) : sealed.encode()
        } catch {
            emit(.failed("Session: envelope failed: \(error.localizedDescription)"))
            return nil
        }
        sendSequence &+= 1

        let destinations: [BoundedSocketFrameWriter]
        if serverFD >= 0 {
            destinations = clients
                .filter { participantID == nil || $0.participant.participantID == participantID }
                .map(\.writer)
        } else if participantID == nil, let guestWriter {
            destinations = [guestWriter]
        } else {
            destinations = []
        }
        guard !destinations.isEmpty else { return nil }
        return (frame, destinations)
    }

    func stop() {
        isActive = false
        runGeneration &+= 1
        stopSockets()
    }

    func clearSession() {
        stop()
        configuration = nil
        authentication = .unconfigured
        outboundSealer = nil
        outboundStreamID = UUID()
        sendSequence = 1
    }

    private func registerClient(
        writer: BoundedSocketFrameWriter,
        participant: ParticipantSession,
        generation: UInt64
    ) {
        guard isActive, generation == runGeneration else {
            writer.stop()
            return
        }
        if let existing = clients.first(where: { $0.participant.participantID == participant.participantID }) {
            removeClient(socket: existing.writer.socket)
        }
        clients.append(ClientConnection(writer: writer, participant: participant))
        emit(.guestJoined(participant))
    }

    private func removeClient(socket: ManagedSocket) {
        guard let index = clients.firstIndex(where: {
            $0.writer.socket === socket
        }) else { return }
        let client = clients.remove(at: index)
        client.writer.stop()
        emit(.guestDisconnected(participantID: client.participant.participantID))
    }

    private func setGuestSocket(_ socket: ManagedSocket, generation: UInt64) {
        guard isActive, generation == runGeneration else {
            socket.cancel()
            return
        }
        guestSocket = socket
    }

    @discardableResult
    private func clearGuestSocket(_ socket: ManagedSocket, generation: UInt64) -> Bool {
        guard guestSocket === socket, generation == runGeneration else { return false }
        guestSocket = nil
        guestWriter = nil
        return isActive
    }

    private func setGuestWriter(_ writer: BoundedSocketFrameWriter, generation: UInt64) {
        guard isActive, generation == runGeneration, guestSocket === writer.socket else {
            writer.stop()
            return
        }
        guestWriter = writer
    }

    private func handleGuestWriterFailure(generation: UInt64) {
        guard generation == runGeneration, guestWriter != nil else { return }
        guestWriter?.stop()
        guestWriter = nil
        guestSocket = nil
        if isActive { emit(.disconnected) }
    }

    private func emit(_ event: SessionControlEvent) {
        eventHandler?(event)
    }

    private func emit(_ event: SessionControlEvent, generation: UInt64) {
        guard generation == runGeneration else { return }
        emit(event)
    }

    private func emitGuest(_ event: SessionControlEvent, socket: ManagedSocket) {
        guard socket.generation == runGeneration, clients.contains(where: { $0.writer.socket === socket }) else { return }
        emit(event)
    }

    private func stopSockets() {
        if serverFD >= 0 {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverFD = -1
        }
        guestWriter?.stop()
        guestSocket?.cancel()
        guestWriter = nil
        guestSocket = nil
        let existingClients = clients
        clients.removeAll()
        for client in existingClients {
            client.writer.stop()
        }
    }

    private enum ControlTransportError: LocalizedError {
        case notConfigured
        case socketFailed(String)
        case bindFailed(String)
        case handshakeWriteFailed
        case invalidWelcome
        /// The guide's sealed handshake frame failed AEAD authentication or its proof mismatched (DSCN-26).
        case credentialRejected
        case guideIdentityRejected

        var errorDescription: String? {
            switch self {
            case .notConfigured: "session is not configured"
            case let .socketFailed(message), let .bindFailed(message): message
            case .handshakeWriteFailed: "handshake write failed"
            case .invalidWelcome: "unexpected welcome envelope"
            case .credentialRejected: "the tour code was rejected by the guide"
            case .guideIdentityRejected: "the admitted guide identity could not be verified"
            }
        }
    }

    nonisolated private static func authenticateGuest(
        fd: Int32,
        configuration: Configuration,
        requestedLane: SessionLane,
        authentication: SessionGuideAuthentication,
        participantSlots: SessionParticipantSlots,
        connectionID: UUID
    ) throws -> (participantID: UUID, displayName: String, platform: ParticipantPlatform) {
        setReceiveTimeout(fd: fd, seconds: 5)
        defer { setReceiveTimeout(fd: fd, seconds: 0) }

        let guideSealer = SessionFrameSealer(credential: configuration.credential)
        let guestOpener = SessionFrameOpener(credential: configuration.credential)
        let handshakeStreamID = UUID()
        let challengeNonce = SessionAuthenticator.randomNonce()
        let challenge = try AuthChallengePayload(
            requestedLane: requestedLane,
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
        let sealedChallenge = try authentication.encodeGuideFrame(guideSealer.seal(challengeEnvelope, streamID: handshakeStreamID))
        guard writeFrame(fd: fd, data: sealedChallenge),
              let frame = readFrame(fd: fd, maximumSize: 65_536),
              let envelope = try openFrame(frame, using: guestOpener) else {
            throw ControlTransportError.invalidWelcome
        }
        guard envelope.sessionID == configuration.sessionID,
              envelope.kind == .hello,
              envelope.lane == .control,
              envelope.senderID != configuration.participantID else {
            throw ControlTransportError.invalidWelcome
        }
        let hello = try HelloPayload.decode(envelope.payload)
        guard hello.role == .guest, hello.requestedLane == requestedLane else {
            throw ControlTransportError.invalidWelcome
        }
        let expectedProof = try SessionAuthenticator.guestProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: configuration.participantID,
            participantID: envelope.senderID,
            requestedLane: requestedLane,
            challengeNonce: challengeNonce,
            clientNonce: hello.clientNonce,
            role: hello.role,
            platform: hello.platform,
            capabilities: hello.capabilities,
            displayName: hello.displayName
        )
        guard SessionAuthenticator.securelyMatches(expectedProof, hello.credentialProof) else {
            throw ControlTransportError.invalidWelcome
        }
        try participantSlots.acquire(participantID: envelope.senderID, connectionID: connectionID)
        let guideNonce = SessionAuthenticator.randomNonce()
        let guideProof = try SessionAuthenticator.guideProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: configuration.participantID,
            participantID: envelope.senderID,
            requestedLane: requestedLane,
            challengeNonce: challengeNonce,
            clientNonce: hello.clientNonce,
            guideNonce: guideNonce
        )
        let welcomePayload = try WelcomePayload(
            requestedLane: requestedLane,
            guideNonce: guideNonce,
            credentialProof: guideProof
        )
        let welcome = try SessionEnvelope(
            lane: .control,
            kind: .welcome,
            sequence: 1,
            sessionID: configuration.sessionID,
            senderID: configuration.participantID,
            payload: welcomePayload.encode()
        )
        let sealedWelcome = try authentication.encodeGuideFrame(guideSealer.seal(welcome, streamID: handshakeStreamID))
        guard writeFrame(fd: fd, data: sealedWelcome) else {
            throw ControlTransportError.handshakeWriteFailed
        }
        return (envelope.senderID, hello.displayName, hello.platform)
    }

    nonisolated private static func authenticateGuide(
        fd: Int32,
        configuration: Configuration,
        requestedLane: SessionLane,
        maximumFrameSize: Int,
        authentication: SessionGuideAuthentication
    ) throws -> UUID {
        guard let challengeFrame = readFrame(fd: fd, maximumSize: maximumFrameSize) else {
            throw ControlTransportError.invalidWelcome
        }
        let guideOpener = SessionFrameOpener(credential: configuration.credential)
        guard let challengeEnvelope = try openHandshakeFrame(challengeFrame, using: guideOpener, authentication: authentication) else {
            throw ControlTransportError.invalidWelcome
        }
        guard challengeEnvelope.sessionID == configuration.sessionID,
              challengeEnvelope.kind == .authChallenge,
              challengeEnvelope.lane == .control,
              challengeEnvelope.senderID != configuration.participantID else {
            throw ControlTransportError.invalidWelcome
        }
        let challenge = try AuthChallengePayload.decode(challengeEnvelope.payload)
        guard challenge.requestedLane == requestedLane else { throw ControlTransportError.invalidWelcome }
        let clientNonce = SessionAuthenticator.randomNonce()
        let proof = try SessionAuthenticator.guestProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: configuration.participantID,
            requestedLane: requestedLane,
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
            requestedLane: requestedLane,
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
        let guestSealer = SessionFrameSealer(credential: configuration.credential)
        let guestStreamID = UUID()
        let sealedHello = try guestSealer.seal(helloEnvelope, streamID: guestStreamID).encode()
        guard writeFrame(fd: fd, data: sealedHello),
              let welcomeFrame = readFrame(fd: fd, maximumSize: maximumFrameSize) else {
            throw ControlTransportError.handshakeWriteFailed
        }
        guard let welcomeEnvelope = try openHandshakeFrame(welcomeFrame, using: guideOpener, authentication: authentication) else {
            throw ControlTransportError.invalidWelcome
        }
        guard welcomeEnvelope.sessionID == configuration.sessionID,
              welcomeEnvelope.kind == .welcome,
              welcomeEnvelope.lane == .control,
              welcomeEnvelope.senderID == challengeEnvelope.senderID else {
            throw ControlTransportError.invalidWelcome
        }
        let welcome = try WelcomePayload.decode(welcomeEnvelope.payload)
        guard welcome.requestedLane == requestedLane else { throw ControlTransportError.invalidWelcome }
        let expectedProof = try SessionAuthenticator.guideProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: configuration.participantID,
            requestedLane: requestedLane,
            challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce,
            guideNonce: welcome.guideNonce
        )
        guard SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof) else {
            throw ControlTransportError.credentialRejected
        }
        return challengeEnvelope.senderID
    }

    nonisolated private static func openFrame(
        _ frame: Data,
        using opener: SessionFrameOpener
    ) throws -> SessionEnvelope? {
        let sealed = try SealedSessionEnvelope.decode(frame)
        switch try opener.open(sealed) {
        case let .opened(envelope):
            return envelope
        case .duplicate:
            return nil
        }
    }

    /// Guest-side handshake open: a wrong tour code fails the AEAD tag on the guide's sealed frame.
    /// Only that failure is a credential rejection (DSCN-26); an EOF from `readFrame` stays a
    /// transport failure and a malformed sealed frame stays a protocol failure.
    nonisolated private static func openHandshakeFrame(
        _ frame: Data,
        using opener: SessionFrameOpener,
        authentication: SessionGuideAuthentication
    ) throws -> SessionEnvelope? {
        do {
            return try openGuideFrame(frame, using: opener, authentication: authentication)
        } catch is GuideSignatureError {
            throw ControlTransportError.guideIdentityRejected
        } catch SessionFrameSecurityError.authenticationFailed {
            throw ControlTransportError.credentialRejected
        }
    }

    nonisolated private static func openGuideFrame(
        _ frame: Data,
        using opener: SessionFrameOpener,
        authentication: SessionGuideAuthentication
    ) throws -> SessionEnvelope? {
        let sealed = try authentication.decodeGuideFrame(frame)
        switch try opener.open(sealed) {
        case let .opened(envelope): return envelope
        case .duplicate: return nil
        }
    }

    nonisolated private static func setNoDelay(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    nonisolated private static func setReceiveTimeout(fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    nonisolated private static func socketError(_ prefix: String) -> String {
        "\(prefix): \(String(cString: strerror(errno)))"
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
        guard readExact(fd: fd, buffer: &header, count: header.count) else { return nil }
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
}

final class LocalSessionControlTransport: SessionControlTransport {
    private let transport: LocalAuthenticatedSessionTransport

    init(port: UInt16 = 50_001, authentication: SessionGuideAuthentication = .unconfigured) {
        transport = LocalAuthenticatedSessionTransport(port: port, applicationLane: .control, authentication: authentication)
    }

    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication) {
        transport.configureGuideAuthentication(authentication)
    }

    var isActive: Bool { transport.isActive }
    var hostIP: String? {
        get { transport.hostIP }
        set { transport.hostIP = newValue }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        transport.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        transport.setEventHandler(handler)
    }

    func startGuide() throws { try transport.startGuide() }
    func startGuest() { transport.startGuest() }
    func send(kind: SessionMessageKind, payload: Data) {
        transport.send(kind: kind, payload: payload, to: nil)
    }
    func sendLeave() async { await transport.sendLeave() }
    func stop() { transport.stop() }
    func clearSession() { transport.clearSession() }
}

final class LocalSessionAssetTransport: SessionAssetTransport {
    private let transport: LocalAuthenticatedSessionTransport

    init(port: UInt16 = 50_002, authentication: SessionGuideAuthentication = .unconfigured) {
        transport = LocalAuthenticatedSessionTransport(port: port, applicationLane: .asset, authentication: authentication)
    }

    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication) {
        transport.configureGuideAuthentication(authentication)
    }

    var isActive: Bool { transport.isActive }
    var hostIP: String? {
        get { transport.hostIP }
        set { transport.hostIP = newValue }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        transport.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?) {
        transport.setEventHandler { event in
            handler?(SessionAssetEvent(event))
        }
    }

    func startGuide() throws { try transport.startGuide() }
    func startGuest() { transport.startGuest() }
    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        transport.send(kind: kind, payload: payload, to: participantID)
    }
    func stop() { transport.stop() }
    func clearSession() { transport.clearSession() }
}

private extension SessionAssetEvent {
    init(_ event: SessionControlEvent) {
        switch event {
        case .connected:
            self = .connected
        case let .guestJoined(participant):
            self = .guestJoined(participant)
        case let .envelopeReceived(envelope):
            self = .envelopeReceived(envelope)
        case let .guestDisconnected(participantID):
            self = .guestDisconnected(participantID: participantID)
        case .disconnected:
            self = .disconnected
        case let .versionMismatch(remoteMajor, localMajor):
            self = .versionMismatch(remoteMajor: remoteMajor, localMajor: localMajor)
        case let .credentialRejected(message):
            self = .credentialRejected(message)
        case let .failed(message):
            self = .failed(message)
        }
    }
}
