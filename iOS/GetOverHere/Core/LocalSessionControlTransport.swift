import Darwin
import Foundation
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
        let fd: Int32
        let participant: ParticipantSession
    }

    private let port: UInt16
    private let applicationLane: SessionLane
    private let maximumFrameSize = 1_048_576
    private let sendQueue = DispatchQueue(label: "session.data.send", qos: .userInitiated)
    private var configuration: Configuration?
    private var eventHandler: (@Sendable (SessionControlEvent) -> Void)?
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var clients: [ClientConnection] = []
    private var acceptTask: Task<Void, Never>?
    private var guestTask: Task<Void, Never>?
    private var sendSequence: UInt64 = 1
    private var outboundSealer: SessionFrameSealer?
    private var outboundStreamID = UUID()

    private(set) var isActive = false
    var hostIP: String?

    init(port: UInt16, applicationLane: SessionLane) {
        self.port = port
        self.applicationLane = applicationLane
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

    func startGuide() {
        guard let configuration else {
            emit(.failed("Session: session is not configured"))
            return
        }

        stop()
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            emit(.failed(Self.socketError("Session: socket failed")))
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
        guard bindResult == 0, Darwin.listen(serverFD, 64) == 0 else {
            emit(.failed(Self.socketError("Session: bind/listen failed")))
            close(serverFD)
            serverFD = -1
            return
        }

        isActive = true
        sendSequence = 1
        outboundSealer = SessionFrameSealer(credential: configuration.credential)
        outboundStreamID = UUID()
        let inboundOpener = SessionFrameOpener(credential: configuration.credential)
        let listeningFD = serverFD
        let expectedApplicationLane = applicationLane

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
                Self.setNoDelay(fd: acceptedFD)

                Task { @concurrent [weak self] in
                    let hello: (participantID: UUID, displayName: String, platform: ParticipantPlatform)
                    do {
                        hello = try Self.authenticateGuest(
                            fd: acceptedFD,
                            configuration: configuration,
                            requestedLane: expectedApplicationLane
                        )
                    } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                        await self?.emit(.versionMismatch(
                            remoteMajor: remoteMajor,
                            localMajor: SealedSessionEnvelope.majorVersion
                        ))
                        close(acceptedFD)
                        return
                    } catch {
                        fputs("Session: invalid guest hello (\(String(describing: type(of: error))))\n", stderr)
                        close(acceptedFD)
                        return
                    }

                    let connectionID = UUID().uuidString
                    let participant = ParticipantSession(
                        participantID: hello.participantID,
                        connectionID: connectionID,
                        displayName: hello.displayName,
                        role: .guest,
                        platform: hello.platform
                    )
                    await self?.registerClient(fd: acceptedFD, participant: participant)
                    while !Task.isCancelled,
                          let frame = Self.readFrame(fd: acceptedFD, maximumSize: 1_048_576) {
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
                            await self?.emit(.envelopeReceived(envelope))
                            if envelope.kind == .leave { break }
                        } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                            await self?.emit(.versionMismatch(
                                remoteMajor: remoteMajor,
                                localMajor: SealedSessionEnvelope.majorVersion
                            ))
                            break
                        } catch {
                            await self?.emit(.failed("Session: invalid guest envelope: \(error.localizedDescription)"))
                            break
                        }
                    }
                    await self?.removeClient(fd: acceptedFD)
                }
            }
        }
    }

    func startGuest() {
        guard let configuration else {
            emit(.failed("Session: session is not configured"))
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

        guestTask = Task { @concurrent [weak self] in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                await self?.emit(.failed(Self.socketError("Session: socket failed")))
                return
            }
            Self.setNoDelay(fd: fd)
            await self?.setClientFD(fd)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = controlPort.bigEndian
            guard inet_pton(AF_INET, hostIP, &address.sin_addr) == 1 else {
                close(fd)
                await self?.clearClientFD(fd)
                await self?.emit(.failed("Session: invalid guide host IP \(hostIP)"))
                return
            }
            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                let message = Self.socketError("Session: connect failed")
                close(fd)
                await self?.clearClientFD(fd)
                await self?.emit(.failed(message))
                return
            }

            Self.setReceiveTimeout(fd: fd, seconds: 5)
            let guideID: UUID
            do {
                guideID = try Self.authenticateGuide(
                    fd: fd,
                    configuration: configuration,
                    requestedLane: expectedApplicationLane,
                    maximumFrameSize: maximumFrameSize
                )
            } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                close(fd)
                await self?.clearClientFD(fd)
                await self?.emit(.versionMismatch(
                    remoteMajor: remoteMajor,
                    localMajor: SealedSessionEnvelope.majorVersion
                ))
                return
            } catch {
                close(fd)
                await self?.clearClientFD(fd)
                await self?.emit(.failed("Session: invalid welcome: \(error.localizedDescription)"))
                return
            }

            Self.setReceiveTimeout(fd: fd, seconds: 0)
            await self?.emit(.connected)
            while !Task.isCancelled,
                  let frame = Self.readFrame(fd: fd, maximumSize: maximumFrameSize) {
                do {
                    guard let envelope = try Self.openFrame(frame, using: inboundOpener) else {
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
                    await self?.emit(.envelopeReceived(envelope))
                } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                    await self?.emit(.versionMismatch(
                        remoteMajor: remoteMajor,
                        localMajor: SealedSessionEnvelope.majorVersion
                    ))
                    break
                } catch {
                    await self?.emit(.failed("Session: invalid guide envelope: \(error.localizedDescription)"))
                    break
                }
            }

            close(fd)
            let wasActive = await self?.clearClientFD(fd) ?? false
            if wasActive { await self?.emit(.disconnected) }
        }
    }

    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        guard kind.requiredLane == applicationLane,
              kind != .hello,
              kind != .authChallenge,
              kind != .welcome else {
            emit(.failed("Session: \(kind) is not valid for the \(applicationLane) lane"))
            return
        }
        guard isActive, let configuration else {
            emit(.failed("Session: transport is not active"))
            return
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
                return
            }
            frame = try outboundSealer.seal(envelope, streamID: outboundStreamID).encode()
        } catch {
            emit(.failed("Session: envelope failed: \(error.localizedDescription)"))
            return
        }
        sendSequence &+= 1

        let destinations: [Int32]
        if serverFD >= 0 {
            destinations = clients
                .filter { participantID == nil || $0.participant.participantID == participantID }
                .map(\.fd)
        } else if participantID == nil, clientFD >= 0 {
            destinations = [clientFD]
        } else {
            destinations = []
        }
        guard !destinations.isEmpty else { return }
        sendQueue.async { [weak self] in
            let dead = destinations.filter { !Self.writeFrame(fd: $0, data: frame) }
            guard !dead.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.serverFD >= 0 {
                    for fd in dead { self.removeClient(fd: fd) }
                } else if let fd = dead.first {
                    let wasActive = self.clearClientFD(fd)
                    close(fd)
                    if wasActive { self.emit(.disconnected) }
                }
            }
        }
    }

    func stop() {
        isActive = false
        acceptTask?.cancel()
        guestTask?.cancel()
        acceptTask = nil
        guestTask = nil
        stopSockets()
    }

    private func registerClient(fd: Int32, participant: ParticipantSession) {
        if let existing = clients.first(where: { $0.participant.participantID == participant.participantID }) {
            removeClient(fd: existing.fd)
        }
        clients.append(ClientConnection(fd: fd, participant: participant))
        emit(.guestJoined(participant))
    }

    private func removeClient(fd: Int32) {
        guard let index = clients.firstIndex(where: { $0.fd == fd }) else { return }
        let client = clients.remove(at: index)
        close(client.fd)
        emit(.guestDisconnected(participantID: client.participant.participantID))
    }

    private func setClientFD(_ fd: Int32) {
        clientFD = fd
    }

    @discardableResult
    private func clearClientFD(_ fd: Int32) -> Bool {
        guard clientFD == fd else { return false }
        clientFD = -1
        return isActive
    }

    private func emit(_ event: SessionControlEvent) {
        eventHandler?(event)
    }

    private func stopSockets() {
        if serverFD >= 0 {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverFD = -1
        }
        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
            clientFD = -1
        }
        let existingClients = clients
        clients.removeAll()
        for client in existingClients {
            shutdown(client.fd, SHUT_RDWR)
            close(client.fd)
        }
    }

    private enum ControlTransportError: LocalizedError {
        case handshakeWriteFailed
        case invalidWelcome

        var errorDescription: String? {
            switch self {
            case .handshakeWriteFailed: "handshake write failed"
            case .invalidWelcome: "unexpected welcome envelope"
            }
        }
    }

    nonisolated private static func authenticateGuest(
        fd: Int32,
        configuration: Configuration,
        requestedLane: SessionLane
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
        let sealedChallenge = try guideSealer.seal(challengeEnvelope, streamID: handshakeStreamID).encode()
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
        let sealedWelcome = try guideSealer.seal(welcome, streamID: handshakeStreamID).encode()
        guard writeFrame(fd: fd, data: sealedWelcome) else {
            throw ControlTransportError.handshakeWriteFailed
        }
        return (envelope.senderID, hello.displayName, hello.platform)
    }

    nonisolated private static func authenticateGuide(
        fd: Int32,
        configuration: Configuration,
        requestedLane: SessionLane,
        maximumFrameSize: Int
    ) throws -> UUID {
        guard let challengeFrame = readFrame(fd: fd, maximumSize: maximumFrameSize) else {
            throw ControlTransportError.invalidWelcome
        }
        let guideOpener = SessionFrameOpener(credential: configuration.credential)
        guard let challengeEnvelope = try openFrame(challengeFrame, using: guideOpener) else {
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
        guard let welcomeEnvelope = try openFrame(welcomeFrame, using: guideOpener) else {
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
            throw ControlTransportError.invalidWelcome
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

    init(port: UInt16 = 50_001) {
        transport = LocalAuthenticatedSessionTransport(port: port, applicationLane: .control)
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

    func startGuide() { transport.startGuide() }
    func startGuest() { transport.startGuest() }
    func send(kind: SessionMessageKind, payload: Data) {
        transport.send(kind: kind, payload: payload, to: nil)
    }
    func stop() { transport.stop() }
}

final class LocalSessionAssetTransport: SessionAssetTransport {
    private let transport: LocalAuthenticatedSessionTransport

    init(port: UInt16 = 50_002) {
        transport = LocalAuthenticatedSessionTransport(port: port, applicationLane: .asset)
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

    func startGuide() { transport.startGuide() }
    func startGuest() { transport.startGuest() }
    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        transport.send(kind: kind, payload: payload, to: participantID)
    }
    func stop() { transport.stop() }
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
        case let .failed(message):
            self = .failed(message)
        }
    }
}
