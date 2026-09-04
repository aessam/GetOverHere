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
        let writer: BoundedSocketFrameWriter
        let connectionID: String
        let participantID: UUID
        let codec: SessionAudioCodec
    }

    nonisolated private final class BroadcastCodecState {
        let encoder: any RealtimeAudioEncoderInterface
        var accumulator: PCMFrameAccumulator
        let streamID = UUID()
        var sequence: UInt64 = 0

        init(encoder: any RealtimeAudioEncoderInterface) throws {
            self.encoder = encoder
            accumulator = try PCMFrameAccumulator(frameByteCount: encoder.inputPCMByteCount)
        }
    }

    nonisolated private final class BroadcastProcessor: @unchecked Sendable {
        private let queue = DispatchQueue(label: "audio.encode.seal", qos: .userInteractive)
        private let lock = NSLock()
        private let configuration: SessionConfiguration
        private let codecProvider: any RealtimeAudioCodecProviderInterface
        private let sealer: SessionFrameSealer
        private let frameLifetimeNanoseconds: UInt64
        private var codecStates: [SessionAudioCodec: BroadcastCodecState] = [:]
        private var sentPacketCount = 0
        private var stopped = false

        init(
            configuration: SessionConfiguration,
            codecProvider: any RealtimeAudioCodecProviderInterface,
            frameLifetimeNanoseconds: UInt64
        ) {
            self.configuration = configuration
            self.codecProvider = codecProvider
            sealer = SessionFrameSealer(credential: configuration.credential)
            self.frameLifetimeNanoseconds = frameLifetimeNanoseconds
        }

        func submit(
            pcm: Data,
            destinations: [SessionAudioCodec: [BoundedSocketFrameWriter]]
        ) {
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            guard !isStopped else { return }
            queue.async { [weak self] in self?.process(pcm: pcm, destinations: destinations) }
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        private func process(
            pcm: Data,
            destinations: [SessionAudioCodec: [BoundedSocketFrameWriter]]
        ) {
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            guard !isStopped else { return }

            for (codec, writers) in destinations where !writers.isEmpty {
                do {
                    let state: BroadcastCodecState
                    if let existing = codecStates[codec] {
                        state = existing
                    } else {
                        let created = try BroadcastCodecState(encoder: codecProvider.makeEncoder(codec: codec))
                        codecStates[codec] = created
                        state = created
                    }
                    for pcmFrame in state.accumulator.append(pcm) {
                        guard let packet = try state.encoder.encode(pcm16LittleEndian: pcmFrame) else { continue }
                        let capturedAt = UDPAudioPlane.wallClockNanoseconds()
                        let payload = try EncodedAudioFramePayload(
                            configuration: packet.configuration,
                            capturedAtNanoseconds: capturedAt,
                            expiresAtNanoseconds: capturedAt + frameLifetimeNanoseconds,
                            encodedBytes: packet.bytes
                        )
                        let envelope = try SessionEnvelope(
                            lane: .realtime,
                            kind: .audioFrame,
                            sequence: state.sequence,
                            sessionID: configuration.sessionID,
                            senderID: configuration.participantID,
                            payload: payload.encode()
                        )
                        let frame = try sealer.seal(envelope, streamID: state.streamID).encode()
                        state.sequence &+= 1
                        sentPacketCount += 1
                        if sentPacketCount == 1 {
                            Logger.audio.info("TCP: sending first encrypted encoded audio frame")
                        }
                        writers.forEach { $0.enqueue(frame) }
                    }
                } catch {
                    Logger.audio.error("TCP: encoded audio frame failed")
                }
            }
        }
    }

    nonisolated private final class CallbackStore: @unchecked Sendable {
        private let lock = NSLock()
        private var audioHandler: (@Sendable (Data) -> Void)?
        private var sessionHandler: (@Sendable (AudioSessionEvent) -> Void)?

        func setAudioHandler(_ handler: (@Sendable (Data) -> Void)?) {
            lock.lock()
            audioHandler = handler
            lock.unlock()
        }

        func setSessionHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {
            lock.lock()
            sessionHandler = handler
            lock.unlock()
        }

        func emitAudio(_ data: Data) {
            lock.lock()
            let handler = audioHandler
            lock.unlock()
            handler?(data)
        }

        func emitSession(_ event: AudioSessionEvent) {
            lock.lock()
            let handler = sessionHandler
            lock.unlock()
            handler?(event)
        }
    }

    private(set) var isActive = false
    var hostIP: String?

    /// Test accessors for socket-option and admission assertions (FND-4).
    var connectedClientDescriptors: [Int32] { connectedClients.map(\.writer.socket.fd) }
    var guestSocketDescriptor: Int32? { guestSocket?.fd }

    private let port: UInt16
    private let maximumFrameSize = 1_048_576
    private let frameLifetimeNanoseconds: UInt64 = 500_000_000
    nonisolated private let codecProvider: any RealtimeAudioCodecProviderInterface
    private var configuration: SessionConfiguration?
    private var serverFD: Int32 = -1
    private var guestSocket: ManagedSocket?
    private var connectedClients: [ClientConnection] = []
    private let acceptQueue = DispatchQueue(label: "audio.tcp.accept", qos: .userInitiated)
    private let guestQueue = DispatchQueue(label: "audio.tcp.guest", qos: .userInteractive)
    private var runGeneration: UInt64 = 0
    nonisolated private let callbacks = CallbackStore()
    /// Accepted-but-unauthenticated connections held at once (RSK-1, ADR-047).
    nonisolated private let handshakeSlots = HandshakeSlots(limit: 32)
    private var broadcastProcessor: BroadcastProcessor?

    init(
        port: UInt16 = 50_000,
        codecProvider: any RealtimeAudioCodecProviderInterface = NativeRealtimeAudioCodecProvider()
    ) {
        self.port = port
        self.codecProvider = codecProvider
    }

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
        callbacks.setSessionHandler(handler)
    }

    // MARK: - Guide

    /// Synchronous and throwing (FND-2): the guide commits state only after the lane is listening.
    func startBroadcasting(channelID: String, quality: AudioQuality) throws {
        guard let configuration, configuration.sessionID.uuidString == channelID.uppercased() else {
            Logger.audio.error("TCP: missing or mismatched GOH2 session configuration")
            throw AudioPlaneStartError.sessionNotConfigured
        }
        let localCapabilities: SessionCapabilities
        do {
            localCapabilities = try codecProvider.sessionCapabilities()
            guard localCapabilities.contains(.opusEncoder) || localCapabilities.contains(.aacLCEncoder) else {
                throw EncodedAudioFrameError.noCommonCodec
            }
        } catch {
            Logger.audio.error("TCP: no native realtime encoder is available")
            throw AudioPlaneStartError.noNativeEncoder
        }

        stopSockets()
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            let message = String(cString: strerror(errno))
            Logger.audio.error("TCP: socket failed: \(message)")
            throw AudioPlaneStartError.socketFailed(message)
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
            let message = String(cString: strerror(errno))
            Logger.audio.error("TCP: bind failed: \(message)")
            close(serverFD)
            serverFD = -1
            throw AudioPlaneStartError.bindFailed(message)
        }
        guard Darwin.listen(serverFD, 64) == 0 else {
            let message = String(cString: strerror(errno))
            Logger.audio.error("TCP: listen failed: \(message)")
            close(serverFD)
            serverFD = -1
            throw AudioPlaneStartError.listenFailed(message)
        }

        isActive = true
        runGeneration &+= 1
        let generation = runGeneration
        broadcastProcessor = BroadcastProcessor(
            configuration: configuration,
            codecProvider: codecProvider,
            frameLifetimeNanoseconds: frameLifetimeNanoseconds
        )
        Logger.audio.info("TCP: GOH2 server listening on port \(self.port)")

        let listeningFD = serverFD
        let handshakeSlots = self.handshakeSlots
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
                    Logger.audio.error("TCP: pending handshake bound reached; closing connection")
                    close(acceptedFD)
                    continue
                }
                Self.setNoDelay(fd: acceptedFD)
                let socket = ManagedSocket(fd: acceptedFD, generation: generation)
                let connectionQueue = DispatchQueue(
                    label: "audio.tcp.client.\(UUID().uuidString)",
                    qos: .userInitiated
                )
                connectionQueue.async { [weak self] in
                    let participant: (
                        participantID: UUID,
                        displayName: String,
                        platform: ParticipantPlatform,
                        codec: SessionAudioCodec
                    )
                    // The slot is held only while the handshake is pending: released on return or throw.
                    let outcome = Result {
                        try Self.authenticateGuest(
                            fd: acceptedFD,
                            configuration: configuration,
                            guideCapabilities: localCapabilities
                        )
                    }
                    handshakeSlots.release()
                    switch outcome {
                    case let .success(value):
                        participant = value
                    case .failure(SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor)):
                        self?.callbacks.emitSession(.versionMismatch(
                            remoteMajor: remoteMajor,
                            localMajor: localMajor
                        ))
                        socket.close()
                        return
                    case .failure:
                        Logger.audio.error("TCP: rejected audio guest")
                        socket.close()
                        return
                    }
                    let connectionID = UUID().uuidString
                    let writer = BoundedSocketFrameWriter(
                        socket: socket,
                        label: "audio.tcp.writer.\(connectionID)",
                        capacity: 4,
                        overflowPolicy: .dropOldest,
                        sendTimeoutMilliseconds: 500
                    ) { [weak self] fd, failedGeneration in
                        Task { @MainActor [weak self] in
                            self?.removeClient(fd: fd, generation: failedGeneration)
                        }
                    }
                    let registration = DispatchSemaphore(value: 0)
                    Task { @MainActor [weak self] in
                        self?.registerClient(
                            writer: writer,
                            connectionID: connectionID,
                            participantID: participant.participantID,
                            displayName: participant.displayName,
                            platform: participant.platform,
                            codec: participant.codec,
                            generation: generation
                        )
                        registration.signal()
                    }
                    registration.wait()
                    guard !socket.isCancelled else { return }

                    var unexpectedByte: UInt8 = 0
                    _ = Darwin.recv(acceptedFD, &unexpectedByte, 1, 0)
                    writer.stop()
                    Task { @MainActor [weak self] in
                        self?.removeClient(fd: acceptedFD, generation: generation)
                    }
                }
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard isActive, !connectedClients.isEmpty, let broadcastProcessor else { return }
        let destinations = Dictionary(grouping: connectedClients, by: \.codec)
            .mapValues { $0.map(\.writer) }
        broadcastProcessor.submit(pcm: data, destinations: destinations)
    }

    // MARK: - Guest

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        callbacks.setAudioHandler(onAudio)
        guard let host = hostIP else {
            Logger.audio.error("TCP: no host IP to connect to")
            return
        }
        guard let configuration, configuration.sessionID.uuidString == channelID.uppercased() else {
            Logger.audio.error("TCP: missing or mismatched GOH2 session configuration")
            return
        }
        let localCapabilities: SessionCapabilities
        do {
            localCapabilities = try codecProvider.sessionCapabilities()
            guard localCapabilities.contains(.opusDecoder) || localCapabilities.contains(.aacLCDecoder) else {
                throw EncodedAudioFrameError.noCommonCodec
            }
        } catch {
            Logger.audio.error("TCP: no native realtime decoder is available")
            return
        }

        stopSockets()
        isActive = true
        runGeneration &+= 1
        let generation = runGeneration
        let audioPort = port
        let maximumFrameSize = maximumFrameSize
        let provider = codecProvider
        guestQueue.async { [weak self] in
            Logger.audio.info("TCP: connecting to guide")
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                Logger.audio.error("TCP: socket failed: \(String(cString: strerror(errno)))")
                self?.callbacks.emitSession(.failed("Guide audio socket failed"))
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
            address.sin_port = audioPort.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                Logger.audio.error("TCP: invalid guide address")
                if !socket.isCancelled {
                    self?.callbacks.emitSession(.failed("Guide audio connection failed"))
                }
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                }
                return
            }

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                Logger.audio.error("TCP: connect failed: \(String(cString: strerror(errno)))")
                if !socket.isCancelled {
                    self?.callbacks.emitSession(.failed("Guide audio connection failed"))
                }
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                }
                return
            }

            let guideID: UUID
            do {
                guideID = try Self.authenticateGuide(
                    fd: fd,
                    configuration: configuration,
                    guestCapabilities: localCapabilities
                )
            } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                self?.callbacks.emitSession(.versionMismatch(
                    remoteMajor: remoteMajor,
                    localMajor: localMajor
                ))
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                }
                return
            } catch AudioAuthenticationError.incompleteHandshake {
                // Transport loss during the handshake (EOF or the 5 s receive timeout).
                Logger.audio.error("TCP: guide audio handshake did not complete")
                if !socket.isCancelled {
                    self?.callbacks.emitSession(.failed("Guide audio handshake did not complete"))
                }
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                }
                return
            } catch {
                // Credential or protocol rejection (a wrong tour code fails to open the guide's
                // sealed challenge; a forged or malformed welcome fails proof validation). Log only:
                // the control lane already reports admission failures and a retry cannot succeed.
                Logger.audio.error("TCP: authentication failed")
                socket.close()
                Task { @MainActor [weak self] in
                    self?.clearGuestSocket(socket, generation: generation)
                }
                return
            }
            Logger.audio.info("TCP: authenticated GOH2 session joined")

            let opener = SessionFrameOpener(credential: configuration.credential)
            var playout: PlayoutClock?
            var receivedPacketCount = 0
            var terminalEventEmitted = false
            while !socket.isCancelled {
                guard let frame = Self.readFrame(fd: fd, maximumSize: maximumFrameSize) else {
                    break
                }
                do {
                    let sealed = try SealedSessionEnvelope.decode(frame)
                    let envelope: SessionEnvelope
                    switch try opener.open(sealed) {
                    case let .opened(opened): envelope = opened
                    case .duplicate: continue
                    }
                    guard envelope.sessionID == configuration.sessionID,
                          envelope.senderID == guideID,
                          envelope.kind == .audioFrame,
                          envelope.lane == .realtime else {
                        Logger.audio.error("TCP: rejected unexpected GOH2 frame")
                        break
                    }
                    receivedPacketCount += 1
                    if receivedPacketCount == 1 {
                        Logger.audio.info("TCP: received first GOH2 audio frame")
                    }
                    let encoded = try EncodedAudioFramePayload.decode(envelope.payload)
                    let now = Self.wallClockNanoseconds()
                    if playout?.configuration != encoded.configuration {
                        // The read loop only offers; the clock drains, decodes, and conceals (ADR-045).
                        playout?.stop()
                        let clock = try PlayoutClock(
                            decoder: provider.makeDecoder(configuration: encoded.configuration),
                            clock: { UDPAudioPlane.wallClockNanoseconds() },
                            emit: { [weak self] pcm in self?.callbacks.emitAudio(pcm) },
                            onDecodeFailure: { [weak self] in
                                self?.callbacks.emitSession(.failed("Native audio decode failed"))
                                socket.cancel()
                            }
                        )
                        clock.start()
                        playout = clock
                    }
                    guard let playout else { continue }
                    _ = playout.offer(
                        SequencedEncodedAudioFrame(sequence: envelope.sequence, payload: encoded),
                        nowNanoseconds: now
                    )
                } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                    self?.callbacks.emitSession(.versionMismatch(
                        remoteMajor: remoteMajor,
                        localMajor: localMajor
                    ))
                    terminalEventEmitted = true
                    break
                } catch {
                    Logger.audio.error("TCP: invalid encrypted audio frame")
                    break
                }
            }
            playout?.stop()
            // Computed before close(): ManagedSocket.close() marks the socket cancelled, which would
            // make a remote loss indistinguishable from a local stop.
            let lostRemotely = !socket.isCancelled && !terminalEventEmitted
            socket.close()
            Task { @MainActor [weak self] in
                self?.clearGuestSocket(socket, generation: generation)
            }
            if lostRemotely {
                self?.callbacks.emitSession(.failed("Guide audio connection closed"))
            }
            Logger.audio.info("TCP: disconnected")
        }
    }

    func stop() {
        isActive = false
        runGeneration &+= 1
        broadcastProcessor?.stop()
        broadcastProcessor = nil
        stopSockets()
        callbacks.setAudioHandler(nil)
        Logger.audio.info("TCP: stopped")
    }

    func clearSession() {
        stop()
        configuration = nil
    }

    private func setGuestSocket(_ socket: ManagedSocket, generation: UInt64) {
        guard isActive, generation == runGeneration else {
            socket.cancel()
            return
        }
        guestSocket = socket
    }

    private func clearGuestSocket(_ socket: ManagedSocket, generation: UInt64) {
        guard generation == runGeneration, guestSocket === socket else { return }
        guestSocket = nil
    }

    // MARK: - Membership

    private func registerClient(
        writer: BoundedSocketFrameWriter,
        connectionID: String,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        codec: SessionAudioCodec,
        generation: UInt64
    ) {
        guard isActive, generation == runGeneration else {
            writer.stop()
            return
        }
        if let existing = connectedClients.first(where: { $0.participantID == participantID }) {
            removeClient(
                fd: existing.writer.socket.fd,
                generation: existing.writer.socket.generation
            )
        }
        connectedClients.append(ClientConnection(
            writer: writer,
            connectionID: connectionID,
            participantID: participantID,
            codec: codec
        ))
        callbacks.emitSession(.joined(ParticipantSession(
            participantID: participantID,
            connectionID: connectionID,
            displayName: displayName,
            role: .guest,
            platform: platform
        )))
        Logger.audio.info("TCP: validated guest session")
    }

    private func removeClient(fd: Int32, generation: UInt64) {
        guard let index = connectedClients.firstIndex(where: {
            $0.writer.socket.fd == fd && $0.writer.socket.generation == generation
        }) else { return }
        let client = connectedClients.remove(at: index)
        client.writer.stop()
        callbacks.emitSession(.disconnected(connectionID: client.connectionID))
    }

    // MARK: - Framing

    nonisolated private static func authenticateGuest(
        fd: Int32,
        configuration: SessionConfiguration,
        guideCapabilities: SessionCapabilities
    ) throws -> (
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        codec: SessionAudioCodec
    ) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        let guideSealer = SessionFrameSealer(credential: configuration.credential)
        let guestOpener = SessionFrameOpener(credential: configuration.credential)
        let handshakeStreamID = UUID()
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
        let sealedChallenge = try guideSealer.seal(
            challengeEnvelope,
            streamID: handshakeStreamID
        ).encode()
        guard writeFrame(fd: fd, data: sealedChallenge),
              let frame = readFrame(fd: fd, maximumSize: 65_536) else {
            throw AudioAuthenticationError.incompleteHandshake
        }
        let sealedHello = try SealedSessionEnvelope.decode(frame)
        guard case let .opened(envelope) = try guestOpener.open(sealedHello),
              envelope.sessionID == configuration.sessionID,
              envelope.kind == .hello,
              envelope.lane == .control,
              envelope.senderID != configuration.participantID else {
            throw AudioAuthenticationError.invalidChallenge
        }
        let hello = try HelloPayload.decode(envelope.payload)
        guard hello.role == .guest, hello.requestedLane == .realtime else {
            throw AudioAuthenticationError.invalidChallenge
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
            throw AudioAuthenticationError.invalidChallenge
        }
        let codec = try SessionAudioCodecNegotiation.preferredCodec(
            sender: guideCapabilities,
            receiver: SessionCapabilities(rawValue: hello.capabilities)
        )
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
            sequence: 1,
            sessionID: configuration.sessionID,
            senderID: configuration.participantID,
            payload: welcomePayload.encode()
        )
        let sealedWelcome = try guideSealer.seal(
            welcome,
            streamID: handshakeStreamID
        ).encode()
        guard writeFrame(fd: fd, data: sealedWelcome) else {
            throw AudioAuthenticationError.incompleteHandshake
        }
        return (envelope.senderID, hello.displayName, hello.platform, codec)
    }

    nonisolated private static func authenticateGuide(
        fd: Int32,
        configuration: SessionConfiguration,
        guestCapabilities: SessionCapabilities
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
        let guideOpener = SessionFrameOpener(credential: configuration.credential)
        let sealedChallenge = try SealedSessionEnvelope.decode(challengeFrame)
        guard case let .opened(challengeEnvelope) = try guideOpener.open(sealedChallenge) else {
            throw AudioAuthenticationError.invalidChallenge
        }
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
            capabilities: guestCapabilities.rawValue,
            displayName: configuration.displayName
        )
        let hello = try HelloPayload(
            role: .guest,
            platform: configuration.platform,
            capabilities: guestCapabilities.rawValue,
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
        let guestSealer = SessionFrameSealer(credential: configuration.credential)
        let sealedHello = try guestSealer.seal(helloEnvelope, streamID: UUID()).encode()
        guard writeFrame(fd: fd, data: sealedHello),
              let welcomeFrame = readFrame(fd: fd, maximumSize: 65_536) else {
            throw AudioAuthenticationError.incompleteHandshake
        }
        let sealedWelcome = try SealedSessionEnvelope.decode(welcomeFrame)
        guard case let .opened(welcomeEnvelope) = try guideOpener.open(sealedWelcome) else {
            throw AudioAuthenticationError.invalidWelcome
        }
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

    nonisolated private static func wallClockNanoseconds() -> UInt64 {
        UInt64((ProcessInfo.processInfo.systemUptime * 1_000_000_000).rounded(.down))
    }

    /// Realtime frames are ~150 bytes every 20 ms; Nagle plus delayed ACK would batch them (FND-4).
    nonisolated private static func setNoDelay(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private func stopSockets() {
        if serverFD >= 0 {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverFD = -1
        }
        guestSocket?.cancel()
        guestSocket = nil
        for client in connectedClients { client.writer.stop() }
        connectedClients.removeAll()
    }
}

/// Clock-driven realtime playout (ADR-045). A timer at the negotiated frame duration drains the
/// jitter buffer on its own queue, decodes there (the native decoder never runs on the read loop),
/// and conceals a single lost frame with one silence frame so the timeline is preserved. Production
/// calls `start()` right after construction; tests drive `tick()` with an injected clock.
nonisolated final class PlayoutClock: @unchecked Sendable {
    let decoder: any RealtimeAudioDecoderInterface
    /// Exactly one negotiated frame of PCM16 zeros: sampleRate * frameDuration / 1000 * channels * 2.
    let silenceFrame: Data

    private let lock = NSLock()
    private var jitter: EncodedAudioJitterBuffer
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private let clock: @Sendable () -> UInt64
    private let emit: @Sendable (Data) -> Void
    private let onDecodeFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "audio.tcp.playout", qos: .userInteractive)

    var configuration: SessionAudioCodecConfiguration { decoder.configuration }

    init(
        decoder: any RealtimeAudioDecoderInterface,
        clock: @escaping @Sendable () -> UInt64,
        emit: @escaping @Sendable (Data) -> Void,
        onDecodeFailure: @escaping @Sendable () -> Void
    ) throws {
        self.decoder = decoder
        self.clock = clock
        self.emit = emit
        self.onDecodeFailure = onDecodeFailure
        let configuration = decoder.configuration
        let duration = Int(configuration.frameDurationMilliseconds)
        let targetFrames = max(1, (60 + duration - 1) / duration)
        let maximumFrames = max(targetFrames, (250 + duration - 1) / duration)
        jitter = try EncodedAudioJitterBuffer(
            targetFrameCount: targetFrames,
            maximumFrameCount: maximumFrames
        )
        silenceFrame = Data(
            count: Int(configuration.sampleRate) * duration / 1_000 * Int(configuration.channelCount) * 2
        )
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        let duration = Int(configuration.frameDurationMilliseconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(duration),
            repeating: .milliseconds(duration),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func offer(_ frame: SequencedEncodedAudioFrame, nowNanoseconds: UInt64) -> EncodedAudioFrameOfferResult {
        lock.lock()
        defer { lock.unlock() }
        return jitter.offer(frame, nowNanoseconds: nowNanoseconds)
    }

    /// One playout period. Runs on `queue` in production; tests call it directly.
    func tick() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        let decision = jitter.popForPlayout(nowNanoseconds: clock())
        lock.unlock()

        switch decision {
        case let .frame(frame):
            do {
                if let pcm = try decoder.decode(packet: frame.payload.encodedBytes) {
                    emit(pcm)
                }
            } catch {
                Logger.audio.error("TCP: native audio decode failed")
                lock.lock()
                let alreadyStopped = stopped
                stopped = true
                lock.unlock()
                if !alreadyStopped { onDecodeFailure() }
            }
        case .conceal:
            emit(silenceFrame)
        case .wait:
            break
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }
}
