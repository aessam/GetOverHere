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

    @Test("GOH2 hello registers the guest and realtime payload arrives")
    @MainActor
    func helloAndAudioRoundtrip() async throws {
        let guide = UDPAudioPlane()
        let guest = UDPAudioPlane()
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let payload = Data([0x10, 0x20, 0x30, 0x40])
        let (events, eventContinuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let (audio, audioContinuation) = AsyncStream.makeStream(of: Data.self)

        defer {
            guest.stop()
            guide.stop()
            eventContinuation.finish()
            audioContinuation.finish()
        }

        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setSessionEventHandler { event in eventContinuation.yield(event) }
        guide.startBroadcasting(channelID: sessionID.uuidString, quality: .standard)

        guest.hostIP = "127.0.0.1"
        guest.configureSession(
            sessionID: sessionID,
            participantID: guestID,
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        guest.startListening(channelID: sessionID.uuidString) { data in
            audioContinuation.yield(data)
        }

        let event = try await next(from: events)
        guard case let .joined(participant) = event else {
            Issue.record("Expected a joined event")
            return
        }
        #expect(participant.participantID == guestID)
        #expect(participant.displayName == "Guest")

        guide.sendAudio(payload)
        #expect(try await next(from: audio) == payload)
    }

    @Test("Independent GOH2 control lane authenticates both directions")
    @MainActor
    func controlLaneRoundtrip() async throws {
        let guide = LocalSessionControlTransport()
        let guest = LocalSessionControlTransport()
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
        let targetID = UUID()
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: SessionControlEvent.self)

        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { guideContinuation.yield($0) }
        guide.startGuide()

        guest.hostIP = "127.0.0.1"
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
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: guideCredential
        )
        guide.startGuide()
        guest.hostIP = "127.0.0.1"
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: guestCredential
        )
        guest.setEventHandler { continuation.yield($0) }
        guest.startGuest()

        let event = try await nextControlEvent(from: events) {
            if case .failed = $0 { true } else { false }
        }
        guard case let .failed(message) = event else {
            Issue.record("Expected authentication failure")
            return
        }
        #expect(message.contains("invalid welcome"))
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

    @Test("Independent GOH2 asset lane supports targeted manifests and guest requests")
    @MainActor
    func assetLaneRoundtrip() async throws {
        let guide = LocalSessionAssetTransport()
        let guest = LocalSessionAssetTransport()
        let sessionID = UUID()
        let guideID = UUID()
        let guestID = UUID()
        let credential = try transportCredential(sessionID)
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

        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guide.setEventHandler { guideContinuation.yield($0) }
        guide.startGuide()

        guest.hostIP = "127.0.0.1"
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

    private func next<Element: Sendable>(from stream: AsyncStream<Element>) async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let element = await iterator.next() else { throw TestTimeout.streamEnded }
                return element
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

    private func nextControlEvent(
        from stream: AsyncStream<SessionControlEvent>,
        matching predicate: @escaping @Sendable (SessionControlEvent) -> Bool
    ) async throws -> SessionControlEvent {
        try await withThrowingTaskGroup(of: SessionControlEvent.self) { group in
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
