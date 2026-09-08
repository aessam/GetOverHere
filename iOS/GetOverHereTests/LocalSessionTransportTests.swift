import Darwin
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite(.serialized)
struct LocalSessionTransportTests {
    private enum TestTimeout: Error {
        case expired
        case streamEnded
    }

    @Test func participantSlotsCountUniqueMembersAndReleaseOnlyTheMatchingConnection() throws {
        let slots = SessionParticipantSlots()
        let participants = (0..<30).map { _ in UUID() }
        let connections = (0..<30).map { _ in UUID() }
        for (participant, connection) in zip(participants, connections) {
            try slots.acquire(participantID: participant, connectionID: connection)
        }
        #expect(slots.participantCount == 30)
        #expect(throws: SessionParticipantCapacityError.self) {
            try slots.acquire(participantID: UUID(), connectionID: UUID())
        }
        let replacement = UUID()
        try slots.acquire(participantID: participants[0], connectionID: replacement)
        slots.release(connections[0]); slots.release(connections[0])
        #expect(slots.participantCount == 30)
        slots.release(replacement)
        #expect(slots.participantCount == 29)
        let newConnection = UUID()
        try slots.acquire(participantID: UUID(), connectionID: newConnection)
        #expect(throws: SessionParticipantCapacityError.self) {
            try slots.acquire(participantID: UUID(), connectionID: newConnection)
        }
        #expect(slots.participantCount == 30)
    }

    @Test("Native signed socket lane rejects member31 before welcome and permits member reconnect; not a radio scale test",
          .timeLimit(.minutes(1)), arguments: [SessionLane.realtime, .control, .asset])
    @MainActor
    func nativeSignedLaneEnforcesThirtyMemberBound(lane: SessionLane) async throws {
        let port: UInt16 = 50_051
        let session = UUID()
        let guideID = UUID()
        let credential = try transportCredential(session)
        let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guideID)
        let control = LocalSessionControlTransport(port: port)
        let assets = LocalSessionAssetTransport(port: port)
        let audio = UDPAudioPlane(port: port, codecProvider: PassThroughRealtimeAudioCodecProvider())
        let (joined, continuation) = AsyncStream.makeStream(of: UUID.self)
        var clients: [RawGuestClient] = []
        defer {
            clients.forEach { $0.close() }
            control.clearSession(); assets.clearSession(); audio.clearSession()
            continuation.finish()
        }
        switch lane {
        case .realtime:
            audio.configureSession(sessionID: session, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
            audio.configureGuideAuthentication(.guide(signer))
            audio.setSessionEventHandler { if case let .joined(participant) = $0 { continuation.yield(participant.participantID) } }
            try audio.startBroadcasting(channelID: session.uuidString, quality: .standard)
        case .control:
            control.configureSession(sessionID: session, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
            control.configureGuideAuthentication(.guide(signer))
            control.setEventHandler { if case let .guestJoined(participant) = $0 { continuation.yield(participant.participantID) } }
            try control.startGuide()
        case .asset:
            assets.configureSession(sessionID: session, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
            assets.configureGuideAuthentication(.guide(signer))
            assets.setEventHandler { if case let .guestJoined(participant) = $0 { continuation.yield(participant.participantID) } }
            try assets.startGuide()
        }
        let participants = (0..<SessionCapacityPolicy.listenerLimit).map { _ in UUID() }
        for participant in participants {
            clients.append(try await signedCapacityGuest(port: port, sessionID: session, participantID: participant,
                credential: credential, lane: lane, verifier: verifier))
            #expect(try await next(from: joined) == participant)
        }
        await #expect(throws: RawGuestClient.ClientError.self) {
            try await signedCapacityGuest(port: port, sessionID: session, participantID: UUID(),
                credential: credential, lane: lane, verifier: verifier)
        }
        clients.append(try await signedCapacityGuest(port: port, sessionID: session, participantID: participants[0],
            credential: credential, lane: lane, verifier: verifier))
        #expect(try await next(from: joined) == participants[0])
        let oldClient = clients[0]
        #expect(await Task { @concurrent in oldClient.readFrame() }.value == nil)
    }

    @concurrent private func signedCapacityGuest(port: UInt16, sessionID: UUID, participantID: UUID,
        credential: SessionCredential, lane: SessionLane, verifier: GuideFrameVerifier) async throws -> RawGuestClient {
        let client = try RawGuestClient(port: port)
        do {
            _ = try client.authenticate(sessionID: sessionID, participantID: participantID, displayName: "Guest",
                platform: .iOS, credential: credential, lane: lane, guideVerifier: verifier,
                capabilities: SessionCapabilities.opusDecoder.rawValue)
            return client
        } catch { client.close(); throw error }
    }

    @Test("GOH2 hello registers the guest and realtime payload arrives", arguments: [false, true])
    @MainActor
    func helloAndAudioRoundtrip(signed: Bool) async throws {
        let provider = PassThroughRealtimeAudioCodecProvider()
        let guide = UDPAudioPlane(codecProvider: provider)
        let guest = UDPAudioPlane(codecProvider: provider)
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let signer = GuideFrameSigner(sessionID: sessionID, guideID: guideID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: sessionID, guideID: guideID)
        let payload = Data([0x10, 0x20, 0x30, 0x40])
        let (events, eventContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let (audio, audioContinuation) = AsyncStream.makeStream(of: (Data, String).self)

        defer {
            guest.stop()
            guide.stop()
            eventContinuation.finish()
            audioContinuation.finish()
        }

        guide.configureGuideAuthentication(signed ? .guide(signer) : .legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setSessionEventHandler { event in eventContinuation.yield(event) }
        try guide.startBroadcasting(channelID: sessionID.uuidString, quality: .standard)

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(signed ? .guest(verifier) : .legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: guestID,
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.startListening(channelID: sessionID.uuidString) { data in
            // FND-5: PCM must be delivered from the clocked playout queue, never the read loop.
            audioContinuation.yield((data, String(cString: __dispatch_queue_get_label(nil))))
        }

        let event = try await next(from: events)
        guard case let .joined(participant) = event else {
            Issue.record("Expected a joined event")
            return
        }
        #expect(participant.participantID == guestID)
        #expect(participant.displayName == "Guest")

        // FND-4: Nagle is disabled on the connecting and the accepted realtime socket (DSCN-18).
        #expect(tcpNoDelay(fd: try #require(guest.guestSocketDescriptor)) != 0)
        #expect(guide.connectedClientDescriptors.count == 1)
        #expect(tcpNoDelay(fd: try #require(guide.connectedClientDescriptors.first)) != 0)

        guide.sendAudio(payload)
        guide.sendAudio(payload)
        guide.sendAudio(payload)
        let (received, deliveryQueueLabel) = try await next(from: audio)
        #expect(received == payload)
        #expect(deliveryQueueLabel == "audio.tcp.playout")
    }

    @Test("Guest audio lane reports the guide closing the realtime socket")
    @MainActor
    func guestAudioLaneReportsGuideClose() async throws {
        let provider = PassThroughRealtimeAudioCodecProvider()
        let guide = UDPAudioPlane(codecProvider: provider)
        let guest = UDPAudioPlane(codecProvider: provider)
        let sessionID = UUID()
        let credential = try transportCredential(sessionID)
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        try startAudioPair(
            guide: guide,
            guest: guest,
            sessionID: sessionID,
            guideCredential: credential,
            guestCredential: credential,
            guideEvents: guideContinuation,
            guestEvents: guestContinuation
        )
        guard case .joined = try await next(from: guideEvents) else {
            Issue.record("Expected a joined event")
            return
        }

        guide.stop()

        guard case let .failed(message) = try await next(from: guestEvents) else {
            Issue.record("Expected the guest audio lane to report the guide close")
            return
        }
        #expect(message == "Guide audio connection closed")
    }

    @Test("Guest audio lane stays silent on a local stop")
    @MainActor
    func guestAudioLaneStaysSilentOnLocalStop() async throws {
        let provider = PassThroughRealtimeAudioCodecProvider()
        let guide = UDPAudioPlane(codecProvider: provider)
        let guest = UDPAudioPlane(codecProvider: provider)
        let sessionID = UUID()
        let credential = try transportCredential(sessionID)
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        try startAudioPair(
            guide: guide,
            guest: guest,
            sessionID: sessionID,
            guideCredential: credential,
            guestCredential: credential,
            guideEvents: guideContinuation,
            guestEvents: guestContinuation
        )
        guard case .joined = try await next(from: guideEvents) else {
            Issue.record("Expected a joined event")
            return
        }

        guest.stop()

        try await expectSilence(on: guestEvents)
    }

    @Test("Audio lane with a wrong tour code is rejected without a reconnect trigger")
    @MainActor
    func audioLaneWrongCodeStaysSilent() async throws {
        let provider = PassThroughRealtimeAudioCodecProvider()
        let guide = UDPAudioPlane(codecProvider: provider)
        let guest = UDPAudioPlane(codecProvider: provider)
        let sessionID = UUID()
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        // RSK-3: the guest opens the guide's sealed challenge with its own credential first, so a
        // wrong code fails AEAD authentication (log only), never the handshake-EOF path.
        try startAudioPair(
            guide: guide,
            guest: guest,
            sessionID: sessionID,
            guideCredential: try transportCredential(sessionID),
            guestCredential: try SessionCredential.derive(shortCode: "23456789AC", sessionID: sessionID),
            guideEvents: guideContinuation,
            guestEvents: guestContinuation
        )

        try await expectSilence(on: guestEvents)
        try await expectSilence(on: guideEvents)
    }

    @Test("Audio lane reports a legacy protocol version explicitly")
    @MainActor
    func audioLaneReportsLegacyVersion() async throws {
        let port: UInt16 = 50_033
        let serverFD = try legacyVersionServer(port: port)
        let serverTask = Task { @concurrent in
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }
            let legacyHeader = Data([0x47, 0x4f, 0x48, 0x32, SessionEnvelope.majorVersion])
            _ = writeTestFrame(fd: clientFD, data: legacyHeader)
        }
        defer {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverTask.cancel()
        }

        let sessionID = UUID()
        let guest = UDPAudioPlane(
            port: port,
            codecProvider: PassThroughRealtimeAudioCodecProvider()
        )
        let (events, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        defer {
            guest.stop()
            continuation.finish()
        }
        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: try transportCredential(sessionID)
        )
        guest.setSessionEventHandler { continuation.yield($0) }
        guest.startListening(channelID: sessionID.uuidString) { _ in }

        let event = try await next(from: events)
        guard case let .versionMismatch(remoteMajor, localMajor) = event else {
            Issue.record("Expected an explicit audio version mismatch")
            return
        }
        #expect(remoteMajor == SessionEnvelope.majorVersion)
        #expect(localMajor == SealedSessionEnvelope.majorVersion)
    }

    @Test("Native codec crosses the encrypted realtime transport", arguments: [false, true])
    @MainActor
    func nativeCodecEncryptedAudioRoundtrip(signed: Bool) async throws {
        let port: UInt16 = 50_034
        let guide = UDPAudioPlane(port: port)
        let guest = UDPAudioPlane(port: port)
        let sessionID = UUID()
        let guideID = UUID()
        let credential = try transportCredential(sessionID)
        let signer = GuideFrameSigner(sessionID: sessionID, guideID: guideID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: sessionID, guideID: guideID)
        let (events, eventContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let (audio, audioContinuation) = AsyncStream.makeStream(of: Data.self)
        defer {
            guest.stop()
            guide.stop()
            eventContinuation.finish()
            audioContinuation.finish()
        }

        guide.configureGuideAuthentication(signed ? .guide(signer) : .legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setSessionEventHandler { eventContinuation.yield($0) }
        try guide.startBroadcasting(channelID: sessionID.uuidString, quality: .standard)

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(signed ? .guest(verifier) : .legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.startListening(channelID: sessionID.uuidString) { audioContinuation.yield($0) }
        guard case .joined = try await next(from: events) else {
            Issue.record("Expected native-codec guest admission")
            return
        }

        let samples = (0 ..< 320).map { index in
            Int16(sin(Double(index) * 0.17) * Double(Int16.max / 4))
        }
        let pcm = samples.withUnsafeBytes { Data($0) }
        for _ in 0 ..< 12 { guide.sendAudio(pcm) }
        let decoded = try await next(from: audio)
        #expect(!decoded.isEmpty)
        #expect(decoded.count.isMultiple(of: MemoryLayout<Int16>.size))
    }

    @Test("Independent GOH2 control lane authenticates both directions", arguments: [false, true])
    @MainActor
    func controlLaneRoundtrip(signed: Bool) async throws {
        let guide = LocalSessionControlTransport()
        let guest = LocalSessionControlTransport()
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let signer = GuideFrameSigner(sessionID: sessionID, guideID: guideID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: sessionID, guideID: guideID)
        let targetID = UUID()
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)

        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        guide.configureGuideAuthentication(signed ? .guide(signer) : .legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { guideContinuation.yield($0) }
        try guide.startGuide()

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(signed ? .guest(verifier) : .legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: guestID,
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.setEventHandler { guestContinuation.yield($0) }
        guest.startGuest()

        let joined = try await nextControlEvent(from: guideEvents) {
            if case .guestJoined = $0 { true } else { false }
        }
        guard case let .guestJoined(participant) = joined else {
            Issue.record("Expected authenticated guest")
            return
        }
        #expect(participant.participantID == guestID)
        _ = try await nextControlEvent(from: guestEvents) {
            if case .connected = $0 { true } else { false }
        }

        let target = try TargetSnapshotPayload(
            stateVersion: 4,
            targetID: targetID,
            latitudeE7: 371_769_000,
            longitudeE7: -35_889_000,
            label: "Main Gate",
            isVisible: true
        )
        guide.send(kind: .targetSnapshot, payload: try target.encode())
        let guestEvent = try await nextControlEvent(from: guestEvents) {
            if case let .envelopeReceived(envelope) = $0 {
                envelope.kind == .targetSnapshot
            } else {
                false
            }
        }
        guard case let .envelopeReceived(targetEnvelope) = guestEvent else {
            Issue.record("Expected target envelope")
            return
        }
        #expect(targetEnvelope.senderID == guideID)
        #expect(try TargetSnapshotPayload.decode(targetEnvelope.payload) == target)

        let focus = VisualFocusSnapshotPayload(stateVersion: 5, mode: .map)
        guide.send(kind: .visualFocusSnapshot, payload: focus.encode())
        let focusEvent = try await nextControlEvent(from: guestEvents) {
            if case let .envelopeReceived(envelope) = $0 {
                envelope.kind == .visualFocusSnapshot
            } else {
                false
            }
        }
        guard case let .envelopeReceived(focusEnvelope) = focusEvent else {
            Issue.record("Expected shared-screen envelope")
            return
        }
        #expect(focusEnvelope.senderID == guideID)
        #expect(try VisualFocusSnapshotPayload.decode(focusEnvelope.payload) == focus)

        guest.send(kind: .heartbeat, payload: Data([0x47, 0x4f, 0x48, 0x32]))
        let guideEvent = try await nextControlEvent(from: guideEvents) {
            if case let .envelopeReceived(envelope) = $0 {
                envelope.kind == .heartbeat
            } else {
                false
            }
        }
        guard case let .envelopeReceived(heartbeat) = guideEvent else {
            Issue.record("Expected heartbeat envelope")
            return
        }
        #expect(heartbeat.senderID == guestID)
        #expect(heartbeat.payload == Data([0x47, 0x4f, 0x48, 0x32]))

        guest.stop()
        let disconnected = try await nextControlEvent(from: guideEvents) {
            if case .guestDisconnected = $0 { true } else { false }
        }
        guard case let .guestDisconnected(participantID) = disconnected else {
            Issue.record("Expected guest disconnect")
            return
        }
        #expect(participantID == guestID)
    }

    @Test("Control lane remains connected while the guide is idle")
    @MainActor
    func controlLaneSurvivesIdleGuide() async throws {
        let port: UInt16 = 50_035
        let guide = LocalSessionControlTransport(port: port)
        let guest = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let credential = try transportCredential(sessionID)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            guest.stop()
            guide.stop()
            guestContinuation.finish()
        }

        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        try guide.startGuide()

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.setEventHandler { guestContinuation.yield($0) }
        guest.startGuest()

        _ = try await nextControlEvent(from: guestEvents) {
            if case .connected = $0 { true } else { false }
        }
        try await Task.sleep(for: .seconds(6))

        let payload = Data([0x47, 0x4f, 0x48, 0x32])
        guide.send(kind: .heartbeat, payload: payload)
        let event = try await nextControlEvent(from: guestEvents) {
            if case let .envelopeReceived(envelope) = $0 {
                envelope.kind == .heartbeat
            } else {
                false
            }
        }
        guard case let .envelopeReceived(envelope) = event else {
            Issue.record("Expected heartbeat after idle interval")
            return
        }
        #expect(envelope.payload == payload)
    }

    @Test("Twenty-four control guests authenticate and each receives a guide control frame")
    @MainActor
    func controlLaneScalesBeyondProcessorCount() async throws {
        let port: UInt16 = 50_036
        let guide = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let credential = try transportCredential(sessionID)
        let guideID = UUID()
        let guestIDs = Set((0 ..< 24).map { _ in UUID() })
        let (events, continuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        let (received, receivedContinuation) = AsyncStream.makeStream(of: UUID.self)
        let guests = guestIDs.enumerated().map { index, guestID in
            let guest = LocalSessionControlTransport(port: port)
            guest.hostIP = "127.0.0.1"
            guest.configureGuideAuthentication(.legacyFixture)
            guest.configureSession(
                sessionID: sessionID,
                participantID: guestID,
                displayName: "Guest \(index)",
                platform: .iOS,
                credential: credential
            )
            guest.setEventHandler { event in
                if case let .envelopeReceived(envelope) = event, envelope.kind == .heartbeat {
                    receivedContinuation.yield(guestID)
                }
            }
            return guest
        }
        defer {
            guests.forEach { $0.stop() }
            guide.stop()
            continuation.finish()
            receivedContinuation.finish()
        }

        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { continuation.yield($0) }
        try guide.startGuide()
        guests.forEach { $0.startGuest() }

        let joined = try await withThrowingTaskGroup(of: Set<UUID>.self) { group in
            group.addTask {
                var participantIDs: Set<UUID> = []
                for await event in events {
                    guard case let .guestJoined(participant) = event else { continue }
                    participantIDs.insert(participant.participantID)
                    if participantIDs.count == guestIDs.count { return participantIDs }
                }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw TestTimeout.expired
            }
            guard let result = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return result
        }
        #expect(joined == guestIDs)

        // FND-12: admission alone proved nothing about fan-out; every guest must get the frame.
        guide.send(kind: .heartbeat, payload: Data([0x47, 0x4f, 0x48, 0x32]))
        let receivedIDs = try await withThrowingTaskGroup(of: Set<UUID>.self) { group in
            group.addTask {
                var participantIDs: Set<UUID> = []
                for await guestID in received {
                    participantIDs.insert(guestID)
                    if participantIDs.count == guestIDs.count { return participantIDs }
                }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw TestTimeout.expired
            }
            guard let result = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return result
        }
        #expect(receivedIDs == guestIDs)
    }

    @Test("One stalled guest does not delay healthy guests")
    @MainActor
    func stalledGuestDoesNotDelayHealthyGuests() async throws {
        let port: UInt16 = 50_037
        let guide = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let credential = try transportCredential(sessionID)
        let healthyIDs = [UUID(), UUID()]
        let stalledID = UUID()
        let frameCount = 8
        let largePayloadSize = 512 * 1_024
        let guideLog = ControlEventLog()
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        let (receipts, receiptContinuation) = AsyncStream.makeStream(of: (UUID, Int).self)
        let healthy = healthyIDs.map { guestID in
            let guest = LocalSessionControlTransport(port: port)
            guest.hostIP = "127.0.0.1"
            guest.configureGuideAuthentication(.legacyFixture)
            guest.configureSession(
                sessionID: sessionID,
                participantID: guestID,
                displayName: "Guest",
                platform: .iOS,
                credential: credential
            )
            guest.setEventHandler { event in
                if case let .envelopeReceived(envelope) = event, envelope.kind == .heartbeat {
                    receiptContinuation.yield((guestID, envelope.payload.count))
                }
            }
            return guest
        }
        var stalled: RawGuestClient?
        defer {
            stalled?.close()
            healthy.forEach { $0.stop() }
            guide.stop()
            guideContinuation.finish()
            receiptContinuation.finish()
        }

        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { event in
            guideLog.append(event)
            guideContinuation.yield(event)
        }
        try guide.startGuide()
        healthy.forEach { $0.startGuest() }
        // An authenticated peer with a 4 KiB receive window that never reads again. The handshake
        // blocks, so it runs off the main actor (the guide registers clients on the main actor).
        stalled = try await Task { @concurrent in
            let client = try RawGuestClient(port: port, receiveBufferBytes: 4_096)
            _ = try client.authenticate(
                sessionID: sessionID,
                participantID: stalledID,
                displayName: "Stalled",
                platform: .iOS,
                credential: credential,
                lane: .control
            )
            return client
        }.value

        var joined: Set<UUID> = []
        for _ in 0 ..< 3 {
            let event = try await nextControlEvent(from: guideEvents) {
                if case .guestJoined = $0 { true } else { false }
            }
            if case let .guestJoined(participant) = event { joined.insert(participant.participantID) }
        }
        #expect(joined == Set(healthyIDs + [stalledID]))

        for index in 0 ..< frameCount {
            guide.send(kind: .heartbeat, payload: Data(repeating: UInt8(index), count: largePayloadSize))
        }
        // ADR-039: healthy peers must not wait on the stalled writer's 2 s send timeout.
        let largeReceipts = try await collectReceipts(
            from: receipts,
            count: healthyIDs.count * frameCount,
            timeout: .seconds(1)
        ) { $0.1 == largePayloadSize }
        #expect(largeReceipts == Dictionary(uniqueKeysWithValues: healthyIDs.map { ($0, frameCount) }))

        let evicted = try await nextControlEvent(from: guideEvents, timeout: .seconds(6)) {
            if case let .guestDisconnected(participantID) = $0 { participantID == stalledID } else { false }
        }
        guard case .guestDisconnected = evicted else {
            Issue.record("Expected the stalled peer to be evicted")
            return
        }

        guide.send(kind: .heartbeat, payload: Data([0x47, 0x4f, 0x48, 0x32]))
        let smallReceipts = try await collectReceipts(
            from: receipts,
            count: healthyIDs.count,
            timeout: .seconds(3)
        ) { $0.1 == 4 }
        #expect(smallReceipts == Dictionary(uniqueKeysWithValues: healthyIDs.map { ($0, 1) }))

        let events = guideLog.events
        #expect(!events.contains {
            if case let .guestDisconnected(participantID) = $0 { healthyIDs.contains(participantID) } else { false }
        })
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Guide disconnects a guest that forges the guide sender ID")
    @MainActor
    func guideDisconnectsGuestThatForgesGuideSenderID() async throws {
        let port: UInt16 = 50_038
        let guide = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let guideLog = ControlEventLog()
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        var raw: RawGuestClient?
        defer {
            raw?.close()
            guide.stop()
            guideContinuation.finish()
        }

        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { event in
            guideLog.append(event)
            guideContinuation.yield(event)
        }
        try guide.startGuide()

        let client = try await Task { @concurrent in
            let client = try RawGuestClient(port: port)
            _ = try client.authenticate(
                sessionID: sessionID,
                participantID: guestID,
                displayName: "Forger",
                platform: .iOS,
                credential: credential,
                lane: .control
            )
            return client
        }.value
        raw = client
        _ = try await nextControlEvent(from: guideEvents) {
            if case let .guestJoined(participant) = $0 { participant.participantID == guestID } else { false }
        }

        // ADR-038: an authenticated guest that stamps the guide's sender ID is dropped.
        try await Task { @concurrent in
            let forged = try SessionEnvelope(
                lane: .control,
                kind: .heartbeat,
                sequence: 1,
                sessionID: sessionID,
                senderID: guideID,
                payload: Data("GOH2".utf8)
            )
            try client.send(forged, sealer: SessionFrameSealer(credential: credential), streamID: UUID())
        }.value

        let disconnected = try await nextControlEvent(from: guideEvents) {
            if case .guestDisconnected = $0 { true } else { false }
        }
        guard case let .guestDisconnected(participantID) = disconnected else {
            Issue.record("Expected the forging guest to be disconnected")
            return
        }
        #expect(participantID == guestID)
        let events = guideLog.events
        #expect(!events.contains { if case .envelopeReceived = $0 { true } else { false } })
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        let eof = await Task { @concurrent in client.readFrame() }.value
        #expect(eof == nil)
    }

    @Test("Guest reconnects after guide restart three times")
    @MainActor
    func guestReconnectsAfterGuideRestartThreeTimes() async throws {
        let port: UInt16 = 50_039
        let guide = LocalSessionControlTransport(port: port)
        let guest = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let guideLog = ControlEventLog()
        let guestLog = ControlEventLog()
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { event in
            guideLog.append(event)
            guideContinuation.yield(event)
        }
        try guide.startGuide()

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: guestID,
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.setEventHandler { event in
            guestLog.append(event)
            guestContinuation.yield(event)
        }
        guest.startGuest()
        _ = try await nextControlEvent(from: guideEvents) {
            if case let .guestJoined(participant) = $0 { participant.participantID == guestID } else { false }
        }
        _ = try await nextControlEvent(from: guestEvents) {
            if case .connected = $0 { true } else { false }
        }

        for cycle in 0 ..< 3 {
            guide.stop()
            try guide.startGuide()
            _ = try await nextControlEvent(from: guestEvents) {
                if case .disconnected = $0 { true } else { false }
            }

            // A local stop must emit nothing. Polling the log keeps the stream intact: cancelling a
            // timed-out AsyncStream consumer would finish the stream for the rest of the test.
            let stopIndex = guestLog.events.count
            guest.stop()
            try await Task.sleep(for: .milliseconds(250))
            #expect(guestLog.events.count == stopIndex, "local stop emitted \(guestLog.events[stopIndex...])")

            guest.startGuest()
            _ = try await nextControlEvent(from: guestEvents) {
                if case .connected = $0 { true } else { false }
            }
            _ = try await nextControlEvent(from: guideEvents) {
                if case let .guestJoined(participant) = $0 { participant.participantID == guestID } else { false }
            }

            guide.send(kind: .heartbeat, payload: Data([UInt8(cycle)]))
            let event = try await nextControlEvent(from: guestEvents) {
                if case let .envelopeReceived(envelope) = $0 { envelope.kind == .heartbeat } else { false }
            }
            guard case let .envelopeReceived(envelope) = event else {
                Issue.record("Expected heartbeat after reconnect \(cycle)")
                return
            }
            #expect(envelope.payload == Data([UInt8(cycle)]))
        }
        #expect(!guideLog.events.contains { if case .failed = $0 { true } else { false } })
        #expect(!guestLog.events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Authenticated guide leave is delivered before transport shutdown")
    @MainActor
    func terminalLeaveArrivesBeforeShutdown() async throws {
        let port: UInt16 = 50_036
        let guide = LocalSessionControlTransport(port: port)
        let guest = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let credential = try transportCredential(sessionID)
        let (events, continuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            guest.stop()
            guide.stop()
            continuation.finish()
        }

        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        try guide.startGuide()
        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.setEventHandler { continuation.yield($0) }
        guest.startGuest()

        _ = try await nextControlEvent(from: events) {
            if case .connected = $0 { true } else { false }
        }
        guide.send(kind: .leave, payload: Data())
        guide.stop()

        let event = try await nextControlEvent(from: events) {
            if case let .envelopeReceived(envelope) = $0 { envelope.kind == .leave } else { false }
        }
        guard case let .envelopeReceived(envelope) = event else {
            Issue.record("Expected terminal leave envelope")
            return
        }
        #expect(envelope.payload.isEmpty)
    }

    @Test("Control lane rejects a guest with the wrong tour code")
    @MainActor
    func controlLaneRejectsWrongCredential() async throws {
        let guide = LocalSessionControlTransport(port: 50_031)
        let guest = LocalSessionControlTransport(port: 50_031)
        let sessionID = UUID()
        let guideCredential = try SessionCredential.derive(
            shortCode: "23456789AB",
            sessionID: sessionID
        )
        let guestCredential = try SessionCredential.derive(
            shortCode: "23456789AC",
            sessionID: sessionID
        )
        let (events, continuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            guest.stop()
            guide.stop()
            continuation.finish()
        }
        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: guideCredential
        )
        try guide.startGuide()
        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: guestCredential
        )
        guest.setEventHandler { continuation.yield($0) }
        guest.startGuest()

        // FND-8: a wrong code is a distinct, terminal event; it is never the retried `.failed`.
        let event = try await next(from: events)
        guard case let .credentialRejected(message) = event else {
            Issue.record("Expected a credential rejection as the first event, got \(event)")
            return
        }
        #expect(message.contains("tour code was rejected"))
        try await expectControlSilence(on: events)
    }

    @Test("Control lane reports a legacy protocol version explicitly")
    @MainActor
    func controlLaneReportsLegacyVersion() async throws {
        let port: UInt16 = 50_032
        let serverFD = try legacyVersionServer(port: port)
        let serverTask = Task { @concurrent in
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }
            let legacyHeader = Data([0x47, 0x4f, 0x48, 0x32, SessionEnvelope.majorVersion])
            _ = writeTestFrame(fd: clientFD, data: legacyHeader)
        }
        defer {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverTask.cancel()
        }

        let sessionID = UUID()
        let guest = LocalSessionControlTransport(port: port)
        let (events, continuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            guest.stop()
            continuation.finish()
        }
        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: try transportCredential(sessionID)
        )
        guest.setEventHandler { continuation.yield($0) }
        guest.startGuest()

        let event = try await nextControlEvent(from: events) {
            if case .versionMismatch = $0 { true } else { false }
        }
        guard case let .versionMismatch(remoteMajor, localMajor) = event else {
            Issue.record("Expected an explicit version mismatch")
            return
        }
        #expect(remoteMajor == SessionEnvelope.majorVersion)
        #expect(localMajor == SealedSessionEnvelope.majorVersion)
    }

    @Test("Terminal clear erases local session credentials")
    @MainActor
    func terminalClearErasesLocalSessionCredentials() async throws {
        let sessionID = UUID()
        let transport = LocalSessionControlTransport(port: 50_033)
        let (events, continuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            transport.clearSession()
            continuation.finish()
        }
        transport.configureGuideAuthentication(.legacyFixture)
        transport.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try transportCredential(sessionID)
        )
        transport.setEventHandler { continuation.yield($0) }
        transport.clearSession()

        // FND-2: a lane that cannot start throws synchronously instead of emitting an asynchronous .failed.
        var thrown: (any Error)?
        do {
            try transport.startGuide()
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.localizedDescription.contains("not configured"))
        #expect(!transport.isActive)
        try await expectControlSilence(on: events)
    }

    @Test("Independent GOH2 asset lane supports targeted manifests and guest requests", arguments: [false, true])
    @MainActor
    func assetLaneRoundtrip(signed: Bool) async throws {
        let guide = LocalSessionAssetTransport()
        let guest = LocalSessionAssetTransport()
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let signer = GuideFrameSigner(sessionID: sessionID, guideID: guideID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: sessionID, guideID: guideID)
        let packID = UUID()
        let hash = String(repeating: "ab", count: 32)
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: SessionAssetEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: SessionAssetEvent.self)

        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        guide.configureGuideAuthentication(signed ? .guide(signer) : .legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { guideContinuation.yield($0) }
        try guide.startGuide()

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(signed ? .guest(verifier) : .legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: guestID,
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.setEventHandler { guestContinuation.yield($0) }
        guest.startGuest()

        _ = try await nextAssetEvent(from: guideEvents) {
            if case .guestJoined = $0 { true } else { false }
        }
        _ = try await nextAssetEvent(from: guestEvents) {
            if case .connected = $0 { true } else { false }
        }

        let asset = try TourAssetDescriptor(
            assetID: "gate-left",
            kind: .slide,
            sha256: hash,
            byteLength: 18,
            order: 0,
            mimeType: "image/jpeg"
        )
        let manifest = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 1,
            displayName: "Alhambra",
            assets: [asset]
        )
        guide.send(kind: .tourPackManifest, payload: try manifest.encode(), to: guestID)
        let manifestEvent = try await nextAssetEvent(from: guestEvents) {
            if case let .envelopeReceived(envelope) = $0 {
                envelope.kind == .tourPackManifest
            } else {
                false
            }
        }
        guard case let .envelopeReceived(manifestEnvelope) = manifestEvent else {
            Issue.record("Expected tour-pack manifest")
            return
        }
        #expect(manifestEnvelope.senderID == guideID)
        #expect(try TourPackManifestPayload.decode(manifestEnvelope.payload) == manifest)

        let request = try AssetRequestPayload(sha256: hash, offset: 7)
        guest.send(kind: .assetRequest, payload: try request.encode(), to: nil)
        let requestEvent = try await nextAssetEvent(from: guideEvents) {
            if case let .envelopeReceived(envelope) = $0 {
                envelope.kind == .assetRequest
            } else {
                false
            }
        }
        guard case let .envelopeReceived(requestEnvelope) = requestEvent else {
            Issue.record("Expected asset request")
            return
        }
        #expect(requestEnvelope.senderID == guestID)
        #expect(try AssetRequestPayload.decode(requestEnvelope.payload) == request)
    }

    @Test("Signed-profile native lanes reject unsigned, wrong-key, tampered and malformed guide challenges",
          arguments: [SessionLane.control, .asset, .realtime], ["unsigned", "wrong-key", "tampered", "malformed"])
    @MainActor
    func signedNativeHandshakeRejectsUntrustedGuide(lane: SessionLane, attack: String) async throws {
        let port: UInt16 = 50_048
        let sessionID = UUID()
        let guideID = UUID()
        let credential = try transportCredential(sessionID)
        let signer = GuideFrameSigner(sessionID: sessionID, guideID: guideID)
        let verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: sessionID, guideID: guideID)
        let envelope = try SessionEnvelope(lane: .control, kind: .authChallenge, sequence: 0,
            sessionID: sessionID, senderID: guideID,
            payload: AuthChallengePayload(requestedLane: lane, challengeNonce: SessionAuthenticator.randomNonce()).encode())
        let sealed = try SessionFrameSealer(credential: credential).seal(envelope, streamID: UUID())
        let frame: Data
        switch attack {
        case "unsigned": frame = sealed.encode()
        case "wrong-key": frame = try GuideFrameSigner(sessionID: sessionID, guideID: guideID).sign(sealed).encode()
        case "tampered":
            var bytes = try signer.sign(sealed).encode()
            bytes[bytes.count - 1] ^= 1
            frame = bytes
        case "malformed": frame = Data(try signer.sign(sealed).encode().dropLast())
        default: throw GuideSignatureError.invalidFrame
        }
        let serverFD = try legacyVersionServer(port: port)
        let serverTask = Task { @concurrent in
            let client = Darwin.accept(serverFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            #expect(writeTestFrame(fd: client, data: frame))
        }
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let control = LocalSessionControlTransport(port: port)
        let assets = LocalSessionAssetTransport(port: port)
        let audio = UDPAudioPlane(port: port, codecProvider: PassThroughRealtimeAudioCodecProvider())
        defer {
            control.clearSession(); assets.clearSession(); audio.clearSession()
            continuation.finish()
            shutdown(serverFD, SHUT_RDWR); close(serverFD); serverTask.cancel()
        }
        switch lane {
        case .control:
            control.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Guest", platform: .iOS, credential: credential)
            control.configureGuideAuthentication(.guest(verifier))
            control.hostIP = "127.0.0.1"
            control.setEventHandler {
                switch $0 {
                case .credentialRejected: continuation.yield("rejected")
                case .connected, .envelopeReceived: continuation.yield("accepted")
                case .failed: continuation.yield("retryable-failure")
                default: break
                }
            }
            control.startGuest()
        case .asset:
            assets.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Guest", platform: .iOS, credential: credential)
            assets.configureGuideAuthentication(.guest(verifier))
            assets.hostIP = "127.0.0.1"
            assets.setEventHandler {
                switch $0 {
                case .credentialRejected: continuation.yield("rejected")
                case .connected, .envelopeReceived: continuation.yield("accepted")
                case .failed: continuation.yield("retryable-failure")
                default: break
                }
            }
            assets.startGuest()
        case .realtime:
            audio.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Guest", platform: .iOS, credential: credential)
            audio.configureGuideAuthentication(.guest(verifier))
            audio.hostIP = "127.0.0.1"
            audio.setSessionEventHandler {
                switch $0 {
                case .authenticationFailed: continuation.yield("rejected")
                case .failed: continuation.yield("retryable-failure")
                default: break
                }
            }
            audio.startListening(channelID: sessionID.uuidString) { _ in continuation.yield("accepted") }
        }
        #expect(try await next(from: events) == "rejected")
    }

    @Test("Native lanes require explicit guide authority and terminal clear erases it")
    @MainActor
    func nativeGuideAuthorityMustBeConfigured() throws {
        let sessionID = UUID()
        let guideID = UUID()
        let credential = try transportCredential(sessionID)
        let control = LocalSessionControlTransport(port: 50_048)
        let assets = LocalSessionAssetTransport(port: 50_049)
        let audio = UDPAudioPlane(port: 50_050, codecProvider: PassThroughRealtimeAudioCodecProvider())
        defer { control.clearSession(); assets.clearSession(); audio.clearSession() }
        control.configureSession(sessionID: sessionID, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
        assets.configureSession(sessionID: sessionID, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
        audio.configureSession(sessionID: sessionID, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
        #expect(throws: SessionGuideAuthenticationError.self) { try control.startGuide() }
        #expect(throws: SessionGuideAuthenticationError.self) { try assets.startGuide() }
        #expect(throws: SessionGuideAuthenticationError.self) { try audio.startBroadcasting(channelID: sessionID.uuidString, quality: .standard) }
        let signer = GuideFrameSigner(sessionID: sessionID, guideID: guideID)
        control.configureGuideAuthentication(.guide(signer))
        try control.startGuide()
        control.stop()
        try control.startGuide()
        control.clearSession()
        control.configureSession(sessionID: sessionID, participantID: guideID, displayName: "Guide", platform: .iOS, credential: credential)
        #expect(throws: SessionGuideAuthenticationError.self) { try control.startGuide() }
    }

    @MainActor
    private func startAudioPair(
        guide: UDPAudioPlane,
        guest: UDPAudioPlane,
        sessionID: UUID,
        guideCredential: SessionCredential,
        guestCredential: SessionCredential,
        guideEvents: AsyncStream<AudioSessionEvent>.Continuation,
        guestEvents: AsyncStream<AudioSessionEvent>.Continuation
    ) throws {
        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: guideCredential
        )
        guide.setSessionEventHandler { guideEvents.yield($0) }
        try guide.startBroadcasting(channelID: sessionID.uuidString, quality: .standard)

        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: guestCredential
        )
        guest.setSessionEventHandler { guestEvents.yield($0) }
        guest.startListening(channelID: sessionID.uuidString) { _ in }
    }

    /// Passes only when no event arrives within 500 ms; any event is recorded as an issue.
    private func expectSilence(on stream: AsyncStream<AudioSessionEvent>) async throws {
        do {
            let event = try await next(from: stream, timeout: .milliseconds(500))
            Issue.record("Unexpected audio session event: \(event)")
        } catch TestTimeout.expired {
            // Silence is the expected outcome.
        }
    }

    /// Passes only when no control event arrives within 500 ms; any event is recorded as an issue.
    private func expectControlSilence(on stream: AsyncStream<SessionControlEvent>) async throws {
        do {
            let event = try await next(from: stream, timeout: .milliseconds(500))
            Issue.record("Unexpected control event: \(event)")
        } catch TestTimeout.expired {
            // Silence is the expected outcome.
        }
    }

    private func tcpNoDelay(fd: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, &length)
        return value
    }

    private func next<Element: Sendable>(
        from stream: AsyncStream<Element>,
        timeout: Duration = .seconds(3)
    ) async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let element = await iterator.next() else { throw TestTimeout.streamEnded }
                return element
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeout.expired
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }

    private func nextControlEvent(
        from stream: AsyncStream<SessionControlEvent>,
        timeout: Duration = .seconds(3),
        matching predicate: @escaping @Sendable (SessionControlEvent) -> Bool
    ) async throws -> SessionControlEvent {
        try await withThrowingTaskGroup(of: SessionControlEvent.self) { group in
            group.addTask {
                for await event in stream where predicate(event) { return event }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeout.expired
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }

    /// Counts matching `(guestID, payloadCount)` receipts per guest until `count` arrived or the
    /// window expired.
    private func collectReceipts(
        from stream: AsyncStream<(UUID, Int)>,
        count: Int,
        timeout: Duration,
        matching predicate: @escaping @Sendable ((UUID, Int)) -> Bool
    ) async throws -> [UUID: Int] {
        try await withThrowingTaskGroup(of: [UUID: Int].self) { group in
            group.addTask {
                var counts: [UUID: Int] = [:]
                var collected = 0
                for await receipt in stream where predicate(receipt) {
                    counts[receipt.0, default: 0] += 1
                    collected += 1
                    if collected == count { return counts }
                }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeout.expired
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }

    private func nextAssetEvent(
        from stream: AsyncStream<SessionAssetEvent>,
        matching predicate: @escaping @Sendable (SessionAssetEvent) -> Bool
    ) async throws -> SessionAssetEvent {
        try await withThrowingTaskGroup(of: SessionAssetEvent.self) { group in
            group.addTask {
                for await event in stream where predicate(event) { return event }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw TestTimeout.expired
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }
}

private func transportCredential(_ sessionID: UUID) throws -> SessionCredential {
    try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
}

/// Records every control event a handler saw so a test can assert on what did not happen.
private final class ControlEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionControlEvent] = []

    func append(_ event: SessionControlEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [SessionControlEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private enum TestSocketError: Error {
    case create
    case bind
    case listen
}

private func legacyVersionServer(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestSocketError.create }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw TestSocketError.bind
    }
    guard Darwin.listen(fd, 1) == 0 else {
        close(fd)
        throw TestSocketError.listen
    }
    return fd
}

private func writeTestFrame(fd: Int32, data: Data) -> Bool {
    var length = UInt32(data.count).bigEndian
    let frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
    return frame.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return false }
        var offset = 0
        while offset < frame.count {
            let count = Darwin.send(fd, base.advanced(by: offset), frame.count - offset, MSG_NOSIGNAL)
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

private final class PassThroughRealtimeAudioCodecProvider: RealtimeAudioCodecProviderInterface {
    func sessionCapabilities() -> SessionCapabilities {
        [.opusEncoder, .opusDecoder]
    }

    func makeEncoder(codec: SessionAudioCodec) throws -> any RealtimeAudioEncoderInterface {
        try PassThroughRealtimeAudioEncoder(codec: codec)
    }

    func makeDecoder(
        configuration: SessionAudioCodecConfiguration
    ) -> any RealtimeAudioDecoderInterface {
        PassThroughRealtimeAudioDecoder(configuration: configuration)
    }
}

private final class PassThroughRealtimeAudioEncoder: RealtimeAudioEncoderInterface {
    let codec: SessionAudioCodec
    let inputPCMByteCount = 4
    private let configuration: SessionAudioCodecConfiguration

    init(codec: SessionAudioCodec) throws {
        self.codec = codec
        configuration = try SessionAudioCodecConfiguration(
            codec: codec,
            sampleRate: 16_000,
            channelCount: 1,
            frameDurationMilliseconds: 20,
            bitRate: 20_000
        )
    }

    func encode(pcm16LittleEndian: Data) -> NativeEncodedAudioPacket? {
        NativeEncodedAudioPacket(configuration: configuration, bytes: pcm16LittleEndian)
    }
}

private final class PassThroughRealtimeAudioDecoder: RealtimeAudioDecoderInterface {
    let configuration: SessionAudioCodecConfiguration

    init(configuration: SessionAudioCodecConfiguration) {
        self.configuration = configuration
    }

    func decode(packet: Data) -> Data? {
        packet
    }
}
