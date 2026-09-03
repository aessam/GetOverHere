import Foundation
import Network
import os
import TourSessionCore

@available(iOS 26.4, *)
private enum WiFiAwareLaneEvent: Sendable {
    case connected
    case guestJoined(ParticipantSession)
    case envelopeReceived(SessionEnvelope)
    case guestDisconnected(participantID: UUID, connectionID: String)
    case disconnected
    case versionMismatch(remoteMajor: UInt8, localMajor: UInt8)
    case failed(String)
}

@MainActor
@available(iOS 26.4, *)
private final class WiFiAwareAuthenticatedLaneTransport {
    private struct Configuration: Sendable {
        let sessionID: UUID
        let participantID: UUID
        let displayName: String
        let platform: ParticipantPlatform
        let credential: SessionCredential
    }

    private struct GuestConnection: Sendable {
        let connection: NetworkConnection<TCP>
        let participant: ParticipantSession
    }

    private enum Role {
        case guide
        case guest
    }

    private let applicationLane: SessionLane
    private let maximumFrameSize = 1_048_576
    private var configuration: Configuration?
    private var role: Role?
    private var eventHandler: (@Sendable (WiFiAwareLaneEvent) -> Void)?
    private var guideConnections: [String: GuestConnection] = [:]
    private var guideTasks: [String: Task<Void, Never>] = [:]
    private var guestConnection: NetworkConnection<TCP>?
    private var guestTask: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private var sendSequence: UInt64 = 1
    private var outboundSealer: SessionFrameSealer?
    private var outboundStreamID = UUID()
    private var inboundOpener: SessionFrameOpener?

    private(set) var isActive = false

    init(applicationLane: SessionLane) {
        self.applicationLane = applicationLane
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        stop()
        configuration = Configuration(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (WiFiAwareLaneEvent) -> Void)?) {
        eventHandler = handler
    }

    func startGuide() {
        guard let configuration else {
            emit(.failed("Aware session is not configured"))
            return
        }
        role = .guide
        sendSequence = 1
        outboundSealer = SessionFrameSealer(credential: configuration.credential)
        outboundStreamID = UUID()
        inboundOpener = SessionFrameOpener(credential: configuration.credential)
        isActive = true
    }

    func startGuest() {
        guard let configuration else {
            emit(.failed("Aware session is not configured"))
            return
        }
        role = .guest
        sendSequence = 1
        outboundSealer = SessionFrameSealer(credential: configuration.credential)
        outboundStreamID = UUID()
        inboundOpener = SessionFrameOpener(credential: configuration.credential)
        isActive = true
    }

    func acceptGuideConnection(_ connection: NetworkConnection<TCP>) {
        guard role == .guide, isActive, let configuration, let inboundOpener else { return }
        let connectionID = connection.id
        guard guideTasks[connectionID] == nil else { return }
        let applicationLane = applicationLane
        let maximumFrameSize = maximumFrameSize
        guideTasks[connectionID] = Task { @concurrent [weak self, connection, configuration] in
            do {
                let hello = try await Self.authenticateGuest(
                    connection: connection,
                    configuration: configuration,
                    applicationLane: applicationLane
                )
                let participant = ParticipantSession(
                    participantID: hello.envelope.senderID,
                    connectionID: connectionID,
                    displayName: hello.payload.displayName,
                    role: .guest,
                    platform: hello.payload.platform
                )
                await self?.registerGuideConnection(connection, participant: participant)

                while !Task.isCancelled {
                    guard let envelope = try Self.openFrame(
                        try await Self.readFrame(from: connection, maximumSize: maximumFrameSize),
                        using: inboundOpener
                    ) else { continue }
                    guard envelope.sessionID == configuration.sessionID,
                          envelope.senderID == participant.participantID,
                          envelope.lane == applicationLane,
                          envelope.kind != .hello,
                          envelope.kind != .authChallenge,
                          envelope.kind != .welcome else {
                        throw WiFiAwareLaneError.invalidEnvelope
                    }
                    await self?.emit(.envelopeReceived(envelope))
                    if envelope.kind == .leave { break }
                }
            } catch is CancellationError {
                // Expected during route replacement or shutdown.
            } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                await self?.emit(.versionMismatch(
                    remoteMajor: remoteMajor,
                    localMajor: localMajor
                ))
            } catch {
                await self?.emit(.failed("Aware guest lane failed"))
            }
            await self?.removeGuideConnection(connectionID: connectionID)
        }
    }

    func connectGuest(_ connection: NetworkConnection<TCP>) {
        guard role == .guest, isActive, let configuration, let inboundOpener else { return }
        guestTask?.cancel()
        guestConnection = connection
        let applicationLane = applicationLane
        let maximumFrameSize = maximumFrameSize
        guestTask = Task { @concurrent [weak self, connection, configuration] in
            var authenticated = false
            do {
                let guideID = try await Self.authenticateGuide(
                    connection: connection,
                    configuration: configuration,
                    applicationLane: applicationLane
                )
                authenticated = true
                await self?.emit(.connected)
                while !Task.isCancelled {
                    guard let envelope = try Self.openFrame(
                        try await Self.readFrame(from: connection, maximumSize: maximumFrameSize),
                        using: inboundOpener
                    ) else { continue }
                    guard envelope.sessionID == configuration.sessionID,
                          envelope.senderID == guideID,
                          envelope.lane == applicationLane,
                          envelope.kind != .hello,
                          envelope.kind != .authChallenge,
                          envelope.kind != .welcome else {
                        throw WiFiAwareLaneError.invalidEnvelope
                    }
                    await self?.emit(.envelopeReceived(envelope))
                }
            } catch is CancellationError {
                // Expected during route replacement or shutdown.
            } catch SessionProtocolError.unsupportedMajorVersion(let remoteMajor, let localMajor) {
                await self?.emit(.versionMismatch(
                    remoteMajor: remoteMajor,
                    localMajor: localMajor
                ))
            } catch {
                await self?.emit(.failed("Aware guide lane failed"))
            }
            let wasCurrent = await self?.clearGuestConnection(connection) ?? false
            if wasCurrent, authenticated {
                await self?.emit(.disconnected)
            }
        }
    }

    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID? = nil) {
        guard kind.requiredLane == applicationLane,
              kind != .hello,
              kind != .authChallenge,
              kind != .welcome else {
            emit(.failed("Aware message used the wrong lane"))
            return
        }
        guard isActive, let configuration, let outboundSealer else { return }

        let encoded: Data
        do {
            let logical = try SessionEnvelope(
                lane: applicationLane,
                kind: kind,
                sequence: sendSequence,
                sessionID: configuration.sessionID,
                senderID: configuration.participantID,
                payload: payload
            )
            encoded = try outboundSealer.seal(
                logical,
                streamID: outboundStreamID
            ).encode()
        } catch {
            emit(.failed("Aware envelope encoding failed"))
            return
        }
        sendSequence &+= 1

        let destinations: [NetworkConnection<TCP>]
        switch role {
        case .guide:
            destinations = guideConnections.values.compactMap { record in
                participantID == nil || record.participant.participantID == participantID
                    ? record.connection
                    : nil
            }
        case .guest:
            destinations = participantID == nil ? [guestConnection].compactMap { $0 } : []
        case nil:
            destinations = []
        }
        guard !destinations.isEmpty else { return }

        let previous = sendTail
        sendTail = Task { @concurrent [weak self] in
            if let previous { await previous.value }
            for destination in destinations {
                do {
                    try await Self.writeFrame(encoded, to: destination)
                } catch {
                    await self?.emit(.failed("Aware lane send failed"))
                }
            }
        }
    }

    func stop() {
        isActive = false
        role = nil
        guideTasks.values.forEach { $0.cancel() }
        guideTasks.removeAll()
        guideConnections.removeAll()
        guestTask?.cancel()
        guestTask = nil
        guestConnection = nil
        sendTail?.cancel()
        sendTail = nil
        outboundSealer = nil
        inboundOpener = nil
    }

    func clearSession() {
        stop()
        configuration = nil
    }

    private func registerGuideConnection(
        _ connection: NetworkConnection<TCP>,
        participant: ParticipantSession
    ) {
        if let existing = guideConnections.values.first(where: {
            $0.participant.participantID == participant.participantID
        }) {
            removeGuideConnection(connectionID: existing.participant.connectionID)
        }
        guideConnections[participant.connectionID] = GuestConnection(
            connection: connection,
            participant: participant
        )
        emit(.guestJoined(participant))
    }

    private func removeGuideConnection(connectionID: String) {
        guideTasks.removeValue(forKey: connectionID)?.cancel()
        guard let removed = guideConnections.removeValue(forKey: connectionID) else { return }
        emit(.guestDisconnected(
            participantID: removed.participant.participantID,
            connectionID: removed.participant.connectionID
        ))
    }

    private func clearGuestConnection(_ connection: NetworkConnection<TCP>) -> Bool {
        guard guestConnection === connection else { return false }
        guestConnection = nil
        return isActive
    }

    private func emit(_ event: WiFiAwareLaneEvent) {
        eventHandler?(event)
    }

    nonisolated private static func writeFrame(
        _ frame: Data,
        to connection: NetworkConnection<TCP>
    ) async throws {
        guard frame.count > 0, frame.count <= Int(UInt32.max) else {
            throw WiFiAwareLaneError.invalidFrameLength
        }
        let length = UInt32(frame.count)
        var packet = Data(capacity: 4 + frame.count)
        packet.append(UInt8((length >> 24) & 0xff))
        packet.append(UInt8((length >> 16) & 0xff))
        packet.append(UInt8((length >> 8) & 0xff))
        packet.append(UInt8(length & 0xff))
        packet.append(frame)
        try await connection.send(packet)
    }

    nonisolated private static func readFrame(
        from connection: NetworkConnection<TCP>,
        maximumSize: Int
    ) async throws -> Data {
        let header = try await connection.receive(exactly: 4).content
        guard header.count == 4 else { throw WiFiAwareLaneError.invalidFrameLength }
        let bytes = [UInt8](header)
        let length = Int(UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3]))
        guard length > 0, length <= maximumSize else {
            throw WiFiAwareLaneError.invalidFrameLength
        }
        let frame = try await connection.receive(exactly: length).content
        guard frame.count == length else { throw WiFiAwareLaneError.invalidFrameLength }
        return frame
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

    nonisolated private static func authenticateGuest(
        connection: NetworkConnection<TCP>,
        configuration: Configuration,
        applicationLane: SessionLane
    ) async throws -> (envelope: SessionEnvelope, payload: HelloPayload) {
        let guideSealer = SessionFrameSealer(credential: configuration.credential)
        let guestOpener = SessionFrameOpener(credential: configuration.credential)
        let handshakeStreamID = UUID()
        let challengeNonce = SessionAuthenticator.randomNonce()
        let challenge = try AuthChallengePayload(
            requestedLane: applicationLane,
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
        try await writeFrame(sealedChallenge, to: connection)
        guard let envelope = try openFrame(
            try await readFrame(from: connection, maximumSize: 65_536),
            using: guestOpener
        ) else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let hello = try HelloPayload.decode(envelope.payload)
        guard envelope.sessionID == configuration.sessionID,
              envelope.kind == .hello,
              envelope.lane == .control,
              envelope.senderID != configuration.participantID,
              hello.role == .guest,
              hello.requestedLane == applicationLane else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let expectedProof = try SessionAuthenticator.guestProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: configuration.participantID,
            participantID: envelope.senderID,
            requestedLane: applicationLane,
            challengeNonce: challengeNonce,
            clientNonce: hello.clientNonce,
            role: hello.role,
            platform: hello.platform,
            capabilities: hello.capabilities,
            displayName: hello.displayName
        )
        guard SessionAuthenticator.securelyMatches(expectedProof, hello.credentialProof) else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let guideNonce = SessionAuthenticator.randomNonce()
        let guideProof = try SessionAuthenticator.guideProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: configuration.participantID,
            participantID: envelope.senderID,
            requestedLane: applicationLane,
            challengeNonce: challengeNonce,
            clientNonce: hello.clientNonce,
            guideNonce: guideNonce
        )
        let welcome = try SessionEnvelope(
            lane: .control,
            kind: .welcome,
            sequence: 1,
            sessionID: configuration.sessionID,
            senderID: configuration.participantID,
            payload: try WelcomePayload(
                requestedLane: applicationLane,
                guideNonce: guideNonce,
                credentialProof: guideProof
            ).encode()
        )
        let sealedWelcome = try guideSealer.seal(
            welcome,
            streamID: handshakeStreamID
        ).encode()
        try await writeFrame(sealedWelcome, to: connection)
        return (envelope, hello)
    }

    nonisolated private static func authenticateGuide(
        connection: NetworkConnection<TCP>,
        configuration: Configuration,
        applicationLane: SessionLane
    ) async throws -> UUID {
        let guideOpener = SessionFrameOpener(credential: configuration.credential)
        guard let challengeEnvelope = try openFrame(
            try await readFrame(from: connection, maximumSize: 65_536),
            using: guideOpener
        ) else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        guard challengeEnvelope.sessionID == configuration.sessionID,
              challengeEnvelope.kind == .authChallenge,
              challengeEnvelope.lane == .control,
              challengeEnvelope.senderID != configuration.participantID else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let challenge = try AuthChallengePayload.decode(challengeEnvelope.payload)
        guard challenge.requestedLane == applicationLane else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let clientNonce = SessionAuthenticator.randomNonce()
        let proof = try SessionAuthenticator.guestProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: configuration.participantID,
            requestedLane: applicationLane,
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
            requestedLane: applicationLane,
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
        try await writeFrame(sealedHello, to: connection)
        guard let welcomeEnvelope = try openFrame(
            try await readFrame(from: connection, maximumSize: 65_536),
            using: guideOpener
        ) else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        guard welcomeEnvelope.sessionID == configuration.sessionID,
              welcomeEnvelope.kind == .welcome,
              welcomeEnvelope.lane == .control,
              welcomeEnvelope.senderID == challengeEnvelope.senderID else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let welcome = try WelcomePayload.decode(welcomeEnvelope.payload)
        guard welcome.requestedLane == applicationLane else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        let expectedProof = try SessionAuthenticator.guideProof(
            credential: configuration.credential,
            sessionID: configuration.sessionID,
            guideID: challengeEnvelope.senderID,
            participantID: configuration.participantID,
            requestedLane: applicationLane,
            challengeNonce: challenge.challengeNonce,
            clientNonce: clientNonce,
            guideNonce: welcome.guideNonce
        )
        guard SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof) else {
            throw WiFiAwareLaneError.authenticationFailed
        }
        return challengeEnvelope.senderID
    }
}

@available(iOS 26.4, *)
private enum WiFiAwareLaneError: Error {
    case invalidFrameLength
    case invalidEnvelope
    case authenticationFailed
}

@MainActor
@available(iOS 26.4, *)
final class WiFiAwareAudioPlane: AudioPlane {
    private let lane = WiFiAwareAuthenticatedLaneTransport(applicationLane: .realtime)
    private var onAudio: (@Sendable (Data) -> Void)?
    private var sessionEventHandler: (@Sendable (AudioSessionEvent) -> Void)?

    var isActive: Bool { lane.isActive }

    init() {
        lane.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        lane.configureSession(
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

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        lane.startGuide()
    }

    func sendAudio(_ data: Data) {
        Logger.audio.error("Wi-Fi Aware raw audio is disabled until encoded route integration")
        sessionEventHandler?(.failed("Wi-Fi Aware audio is not available in this build"))
    }

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        self.onAudio = onAudio
        lane.startGuest()
    }

    func stop() {
        lane.stop()
        onAudio = nil
    }
    func clearSession() {
        lane.clearSession()
        onAudio = nil
    }

    func acceptGuideConnection(_ connection: NetworkConnection<TCP>) {
        lane.acceptGuideConnection(connection)
    }

    func connectGuest(_ connection: NetworkConnection<TCP>) {
        lane.connectGuest(connection)
    }

    private func handle(_ event: WiFiAwareLaneEvent) {
        switch event {
        case let .guestJoined(participant):
            sessionEventHandler?(.joined(participant))
        case let .guestDisconnected(_, connectionID):
            sessionEventHandler?(.disconnected(connectionID: connectionID))
        case let .envelopeReceived(envelope):
            guard envelope.kind == .audioFrame, envelope.lane == .realtime else { return }
            sessionEventHandler?(.failed("Wi-Fi Aware encoded audio is not available in this build"))
        case let .versionMismatch(remoteMajor, localMajor):
            sessionEventHandler?(.versionMismatch(remoteMajor: remoteMajor, localMajor: localMajor))
        case let .failed(message):
            sessionEventHandler?(.failed(message))
        case .connected, .disconnected:
            break
        }
    }
}

@MainActor
@available(iOS 26.4, *)
final class WiFiAwareSessionControlTransport: SessionControlTransport {
    private let lane = WiFiAwareAuthenticatedLaneTransport(applicationLane: .control)
    private var handler: (@Sendable (SessionControlEvent) -> Void)?

    var isActive: Bool { lane.isActive }
    var hostIP: String?

    init() {
        lane.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        lane.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() { lane.startGuide() }
    func startGuest() { lane.startGuest() }
    func send(kind: SessionMessageKind, payload: Data) { lane.send(kind: kind, payload: payload) }
    func stop() { lane.stop() }
    func clearSession() { lane.clearSession() }
    func acceptGuideConnection(_ connection: NetworkConnection<TCP>) { lane.acceptGuideConnection(connection) }
    func connectGuest(_ connection: NetworkConnection<TCP>) { lane.connectGuest(connection) }

    private func handle(_ event: WiFiAwareLaneEvent) {
        switch event {
        case .connected: handler?(.connected)
        case let .guestJoined(participant): handler?(.guestJoined(participant))
        case let .envelopeReceived(envelope): handler?(.envelopeReceived(envelope))
        case let .guestDisconnected(participantID, _): handler?(.guestDisconnected(participantID: participantID))
        case .disconnected: handler?(.disconnected)
        case let .versionMismatch(remoteMajor, localMajor):
            handler?(.versionMismatch(remoteMajor: remoteMajor, localMajor: localMajor))
        case let .failed(message): handler?(.failed(message))
        }
    }
}

@MainActor
@available(iOS 26.4, *)
final class WiFiAwareSessionAssetTransport: SessionAssetTransport {
    private let lane = WiFiAwareAuthenticatedLaneTransport(applicationLane: .asset)
    private var handler: (@Sendable (SessionAssetEvent) -> Void)?

    var isActive: Bool { lane.isActive }
    var hostIP: String?

    init() {
        lane.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        lane.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() { lane.startGuide() }
    func startGuest() { lane.startGuest() }
    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        lane.send(kind: kind, payload: payload, to: participantID)
    }
    func stop() { lane.stop() }
    func clearSession() { lane.clearSession() }
    func acceptGuideConnection(_ connection: NetworkConnection<TCP>) { lane.acceptGuideConnection(connection) }
    func connectGuest(_ connection: NetworkConnection<TCP>) { lane.connectGuest(connection) }

    private func handle(_ event: WiFiAwareLaneEvent) {
        switch event {
        case .connected: handler?(.connected)
        case let .guestJoined(participant): handler?(.guestJoined(participant))
        case let .envelopeReceived(envelope): handler?(.envelopeReceived(envelope))
        case let .guestDisconnected(participantID, _): handler?(.guestDisconnected(participantID: participantID))
        case .disconnected: handler?(.disconnected)
        case let .versionMismatch(remoteMajor, localMajor):
            handler?(.versionMismatch(remoteMajor: remoteMajor, localMajor: localMajor))
        case let .failed(message): handler?(.failed(message))
        }
    }
}
