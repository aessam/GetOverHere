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

    nonisolated private final class ReceiveCodecState {
        let decoder: any RealtimeAudioDecoderInterface
        var jitter: EncodedAudioJitterBuffer

        init(decoder: any RealtimeAudioDecoderInterface) throws {
            self.decoder = decoder
            let duration = Int(decoder.configuration.frameDurationMilliseconds)
            let targetFrames = max(1, (60 + duration - 1) / duration)
            let maximumFrames = max(targetFrames, (250 + duration - 1) / duration)
            jitter = try EncodedAudioJitterBuffer(
                targetFrameCount: targetFrames,
                maximumFrameCount: maximumFrames
            )
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

    private let port: UInt16
    private let maximumFrameSize = 1_048_576
    private let frameLifetimeNanoseconds: UInt64 = 500_000_000
    nonisolated private let codecProvider: any RealtimeAudioCodecProviderInterface
    private var configuration: SessionConfiguration?
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var connectedClients: [ClientConnection] = []
    private let sendQueue = DispatchQueue(label: "audio.tcp.send", qos: .userInteractive)
    private var recvTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    nonisolated private let callbacks = CallbackStore()
    private var outboundSealer: SessionFrameSealer?
    private var codecStates: [SessionAudioCodec: BroadcastCodecState] = [:]
    private var sentPacketCount = 0
    private var receivedPacketCount = 0

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

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        guard let configuration, configuration.sessionID.uuidString == channelID.uppercased() else {
            Logger.audio.error("TCP: missing or mismatched GOH2 session configuration")
            return
        }
        let localCapabilities: SessionCapabilities
        do {
            localCapabilities = try codecProvider.sessionCapabilities()
            guard localCapabilities.contains(.opusEncoder) || localCapabilities.contains(.aacLCEncoder) else {
                throw EncodedAudioFrameError.noCommonCodec
            }
        } catch {
            Logger.audio.error("TCP: no native realtime encoder is available")
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
        outboundSealer = SessionFrameSealer(credential: configuration.credential)
        codecStates.removeAll()
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
                    let participant: (
                        participantID: UUID,
                        displayName: String,
                        platform: ParticipantPlatform,
                        codec: SessionAudioCodec
                    )
                    do {
                        participant = try Self.authenticateGuest(
                            fd: acceptedFD,
                            configuration: configuration,
                            guideCapabilities: localCapabilities
                        )
                    } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                        self?.callbacks.emitSession(.versionMismatch(
                            remoteMajor: remoteMajor,
                            localMajor: SealedSessionEnvelope.majorVersion
                        ))
                        close(acceptedFD)
                        return
                    } catch {
                        Logger.audio.error("TCP: rejected audio guest")
                        close(acceptedFD)
                        return
                    }
                    let connectionID = UUID().uuidString
                    await self?.registerClient(
                        fd: acceptedFD,
                        connectionID: connectionID,
                        participantID: participant.participantID,
                        displayName: participant.displayName,
                        platform: participant.platform,
                        codec: participant.codec
                    )

                    var unexpectedByte: UInt8 = 0
                    _ = Darwin.recv(acceptedFD, &unexpectedByte, 1, 0)
                    await self?.removeClient(fd: acceptedFD)
                }
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard isActive, !connectedClients.isEmpty, let configuration, let outboundSealer else { return }

        var deliveries: [(frame: Data, clients: [ClientConnection])] = []
        for (codec, clients) in Dictionary(grouping: connectedClients, by: \.codec) {
            do {
                let state: BroadcastCodecState
                if let existing = codecStates[codec] {
                    state = existing
                } else {
                    let created = try BroadcastCodecState(encoder: codecProvider.makeEncoder(codec: codec))
                    codecStates[codec] = created
                    state = created
                }
                for pcmFrame in state.accumulator.append(data) {
                    guard let packet = try state.encoder.encode(pcm16LittleEndian: pcmFrame) else { continue }
                    let capturedAt = Self.wallClockNanoseconds()
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
                    let frame = try outboundSealer.seal(
                        envelope,
                        streamID: state.streamID
                    ).encode()
                    state.sequence &+= 1
                    deliveries.append((frame, clients))
                }
            } catch {
                Logger.audio.error("TCP: encoded audio frame failed")
            }
        }
        guard !deliveries.isEmpty else { return }

        sendQueue.async { [weak self] in
            guard let self else { return }
            var dead: [Int32] = []
            for delivery in deliveries {
                self.sentPacketCount += 1
                if self.sentPacketCount == 1 {
                    Logger.audio.info("TCP: sending first encrypted encoded audio frame")
                }
                dead.append(contentsOf: delivery.clients.compactMap { client in
                    Self.writeFrame(fd: client.fd, data: delivery.frame) ? nil : client.fd
                })
            }
            guard !dead.isEmpty else { return }
            let deadConnections = Set(dead)
            Task { @MainActor [weak self] in
                for fd in deadConnections { self?.removeClient(fd: fd) }
            }
        }
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

        isActive = true
        receivedPacketCount = 0
        let audioPort = port
        recvTask = Task { @concurrent [weak self] in
            Logger.audio.info("TCP: connecting to guide")
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                Logger.audio.error("TCP: socket failed: \(String(cString: strerror(errno)))")
                return
            }
            await self?.setClientFD(fd)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = audioPort.bigEndian
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
                guideID = try Self.authenticateGuide(
                    fd: fd,
                    configuration: configuration,
                    guestCapabilities: localCapabilities
                )
            } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                self?.callbacks.emitSession(.versionMismatch(
                    remoteMajor: remoteMajor,
                    localMajor: SealedSessionEnvelope.majorVersion
                ))
                close(fd)
                return
            } catch {
                Logger.audio.error("TCP: authentication failed")
                close(fd)
                return
            }
            Logger.audio.info("TCP: authenticated GOH2 session joined")

            let opener = SessionFrameOpener(credential: configuration.credential)
            var decodeState: ReceiveCodecState?
            while !Task.isCancelled {
                guard let frame = Self.readFrame(fd: fd, maximumSize: self?.maximumFrameSize ?? 1_048_576) else {
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
                    await self?.noteReceivedPacket()
                    let encoded = try EncodedAudioFramePayload.decode(envelope.payload)
                    let now = Self.wallClockNanoseconds()
                    if decodeState?.decoder.configuration != encoded.configuration {
                        guard let provider = self?.codecProvider else { break }
                        decodeState = try ReceiveCodecState(
                            decoder: provider.makeDecoder(configuration: encoded.configuration)
                        )
                    }
                    guard let decodeState else { continue }
                    let result = decodeState.jitter.offer(
                        SequencedEncodedAudioFrame(sequence: envelope.sequence, payload: encoded),
                        nowNanoseconds: now
                    )
                    guard result == .accepted else { continue }
                    while let ready = decodeState.jitter.popReady(
                        nowNanoseconds: Self.wallClockNanoseconds()
                    ) {
                        if let pcm = try decodeState.decoder.decode(packet: ready.payload.encodedBytes) {
                            self?.callbacks.emitAudio(pcm)
                        }
                    }
                } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor) {
                    self?.callbacks.emitSession(.versionMismatch(
                        remoteMajor: remoteMajor,
                        localMajor: SealedSessionEnvelope.majorVersion
                    ))
                    break
                } catch {
                    Logger.audio.error("TCP: invalid encrypted audio frame")
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
        callbacks.setAudioHandler(nil)
        Logger.audio.info("TCP: stopped")
    }

    private func setClientFD(_ fd: Int32) {
        clientFD = fd
    }

    private func noteReceivedPacket() {
        receivedPacketCount += 1
        if receivedPacketCount == 1 {
            Logger.audio.info("TCP: received first GOH2 audio frame")
        }
    }

    // MARK: - Membership

    private func registerClient(
        fd: Int32,
        connectionID: String,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        codec: SessionAudioCodec
    ) {
        if let existing = connectedClients.first(where: { $0.participantID == participantID }) {
            removeClient(fd: existing.fd)
        }
        connectedClients.append(ClientConnection(
            fd: fd,
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

    private func removeClient(fd: Int32) {
        guard let index = connectedClients.firstIndex(where: { $0.fd == fd }) else { return }
        let client = connectedClients.remove(at: index)
        close(client.fd)
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
        codecStates.removeAll()
        outboundSealer = nil
    }
}
