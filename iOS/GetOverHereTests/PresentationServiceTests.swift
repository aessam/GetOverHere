import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Presentation service", .serialized)
struct PresentationServiceTests {
    @Test("Guide late join restores presentation, target pin, and pointer snapshots")
    @MainActor
    func guideNavigationAndLateJoin() async throws {
        let transport = RecordingControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID()
        let deckID = UUID()
        let first = try slide("gate", order: 0)
        let second = try slide("court", order: 1)

        service.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        try service.startGuide(deckID: deckID, slides: [second, first])
        try service.showSlide()
        try service.goNext()
        try service.setTarget(
            latitude: 37.176_128_4,
            longitude: -3.588_141_2,
            label: "Main Gate"
        )
        try service.shareBearing(degrees: 271.25)

        #expect(service.currentSlideID == "court")
        #expect(service.isVisible)
        #expect(service.snapshot?.stateVersion == 2)
        #expect(transport.sent.map(\.kind) == [
            .presentationSnapshot,
            .presentationSnapshot,
            .targetSnapshot,
            .visualFocusSnapshot,
            .bearingSnapshot,
            .visualFocusSnapshot,
        ])

        await transport.emit(.guestJoined(ParticipantSession(
            participantID: UUID(),
            connectionID: "guest-1",
            displayName: "Guest",
            role: .guest,
            platform: .android
        )))

        #expect(transport.sent.count == 10)
        #expect(transport.sent.suffix(4).map(\.kind) == [
            .presentationSnapshot,
            .targetSnapshot,
            .bearingSnapshot,
            .visualFocusSnapshot,
        ])
        let latePresentation = try PresentationSnapshotPayload.decode(transport.sent[6].payload)
        let lateTarget = try TargetSnapshotPayload.decode(transport.sent[7].payload)
        let lateBearing = try BearingSnapshotPayload.decode(transport.sent[8].payload)
        let lateFocus = try VisualFocusSnapshotPayload.decode(transport.sent[9].payload)
        #expect(latePresentation == service.snapshot)
        #expect(lateTarget == service.targetSnapshot)
        #expect(lateBearing == service.bearingSnapshot)
        #expect(lateFocus == service.visualFocusSnapshot)
        #expect(lateFocus.mode == .pointer)
    }

    @Test("Guest ignores stale presentation snapshots")
    @MainActor
    func guestRejectsStaleSnapshot() async throws {
        let transport = RecordingControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID()
        let guideID = UUID()
        let deckID = UUID()

        service.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        service.startGuest(hostIP: "127.0.0.1")

        try await transport.emitSnapshot(
            PresentationSnapshotPayload(
                stateVersion: 4,
                deckID: deckID,
                currentSlideID: "court",
                isVisible: true,
                effectiveAtMilliseconds: 400
            ),
            sessionID: sessionID,
            guideID: guideID
        )
        try await transport.emitSnapshot(
            PresentationSnapshotPayload(
                stateVersion: 3,
                deckID: deckID,
                currentSlideID: "gate",
                isVisible: false,
                effectiveAtMilliseconds: 300
            ),
            sessionID: sessionID,
            guideID: guideID
        )

        #expect(service.snapshot?.stateVersion == 4)
        #expect(service.currentSlideID == "court")
        #expect(service.isVisible)

        try await transport.emitTarget(
            try TargetSnapshotPayload(
                stateVersion: 8,
                targetID: UUID(),
                latitudeE7: 371_700_000,
                longitudeE7: -31_880_000,
                label: "Main Gate",
                isVisible: true
            ),
            sessionID: sessionID,
            guideID: guideID
        )
        try await transport.emitTarget(
            try TargetSnapshotPayload(
                stateVersion: 7,
                targetID: UUID(),
                latitudeE7: 0,
                longitudeE7: 0,
                label: "Stale",
                isVisible: false
            ),
            sessionID: sessionID,
            guideID: guideID
        )
        #expect(service.targetSnapshot?.stateVersion == 8)
        #expect(service.targetSnapshot?.label == "Main Gate")

        try await transport.emitVisualFocus(
            VisualFocusSnapshotPayload(stateVersion: 6, mode: .pointer),
            sessionID: sessionID,
            guideID: guideID
        )
        try await transport.emitVisualFocus(
            VisualFocusSnapshotPayload(stateVersion: 5, mode: .map),
            sessionID: sessionID,
            guideID: guideID
        )
        #expect(service.visualFocusSnapshot?.stateVersion == 6)
        #expect(service.visualFocusSnapshot?.mode == .pointer)
    }

    @Test("Guide publishes only selected target coordinates")
    @MainActor
    func guidePublishesSelectedTarget() throws {
        let transport = RecordingControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID()
        service.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        try service.startGuide(deckID: UUID())

        try service.setTarget(latitude: 37.176_128_4, longitude: -3.588_141_2, label: "Main Gate")

        #expect(transport.sent.count == 2)
        #expect(transport.sent[0].kind == .targetSnapshot)
        let target = try TargetSnapshotPayload.decode(transport.sent[0].payload)
        #expect(target.latitudeE7 == 371_761_284)
        #expect(target.longitudeE7 == -35_881_412)
        #expect(target.label == "Main Gate")
        #expect(transport.sent[1].kind == .visualFocusSnapshot)
        #expect(try VisualFocusSnapshotPayload.decode(transport.sent[1].payload).mode == .map)
    }

    @Test("Guide publishes and clears a magnetic pointer")
    @MainActor
    func guidePublishesBearing() throws {
        let transport = RecordingControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID()
        service.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        try service.startGuide(deckID: UUID())

        try service.shareBearing(degrees: 271.25)
        try service.clearBearing()

        #expect(transport.sent.map(\.kind) == [
            .bearingSnapshot,
            .visualFocusSnapshot,
            .bearingSnapshot,
        ])
        let shown = try BearingSnapshotPayload.decode(transport.sent[0].payload)
        let hidden = try BearingSnapshotPayload.decode(transport.sent[2].payload)
        #expect(shown.reference == .magnetic)
        #expect(shown.bearingMilliDegrees == 271_250)
        #expect(shown.isVisible)
        #expect(!hidden.isVisible)
        #expect(hidden.stateVersion == shown.stateVersion + 1)
        #expect(try VisualFocusSnapshotPayload.decode(transport.sent[1].payload).mode == .pointer)
    }

    @Test("Authenticated leave distinguishes session end from discovery loss")
    @MainActor
    func authenticatedSessionEnd() async throws {
        let guideTransport = RecordingControlTransport()
        let guide = TourControlService(transport: guideTransport)
        let sessionID = UUID()
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        try guide.startGuide(deckID: UUID())
        try await guide.endGuideSession()
        #expect(guideTransport.leaveFlushCount == 1)
        #expect(guideTransport.sent.last?.kind == .leave)
        #expect(guideTransport.sent.last?.payload.isEmpty == true)

        let guestTransport = RecordingControlTransport()
        let guest = TourControlService(transport: guestTransport)
        let guideID = UUID()
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        guest.startGuest(hostIP: "127.0.0.1")
        let leaveEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .leave,
            sequence: 9,
            sessionID: sessionID,
            senderID: guideID,
            payload: Data()
        )

        await confirmation("Guest observes authenticated session end") { ended in
            guest.setConnectionEventHandler { event in
                if case .sessionEnded = event { ended() }
            }
            await guestTransport.emit(.envelopeReceived(leaveEnvelope))
        }
    }

    @Test("Connected guest count follows control-lane membership with set semantics")
    @MainActor
    func connectedGuestCountFollowsControlLaneMembership() async throws {
        let transport = RecordingControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID()
        service.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try presentationCredential(sessionID)
        )
        try service.startGuide(deckID: UUID())
        let guestA = UUID()
        let guestB = UUID()

        await transport.emit(.guestJoined(participant(guestA, connectionID: "a-1")))
        await transport.emit(.guestJoined(participant(guestB, connectionID: "b-1")))
        #expect(service.connectedGuestCount == 2)

        await transport.emit(.guestDisconnected(participantID: guestA))
        #expect(service.connectedGuestCount == 1)
        await transport.emit(.guestDisconnected(participantID: guestA))
        #expect(service.connectedGuestCount == 1, "disconnect is idempotent")

        // A re-registering guest arrives as disconnect + join and must count once.
        await transport.emit(.guestDisconnected(participantID: guestB))
        await transport.emit(.guestJoined(participant(guestB, connectionID: "b-2")))
        #expect(service.connectedGuestCount == 1)

        service.stop()
        #expect(service.connectedGuestCount == 0)
    }

    private func participant(_ id: UUID, connectionID: String) -> ParticipantSession {
        ParticipantSession(
            participantID: id,
            connectionID: connectionID,
            displayName: "Guest",
            role: .guest,
            platform: .android
        )
    }

    @Test("Discovery unavailable command roundtrips separately from session end")
    @MainActor
    func discoveryUnavailableRoundtrip() throws {
        let channelID = UUID().uuidString
        let encoded = try JSONEncoder().encode(BLECommand.channelUnavailable(channelID: channelID))
        let decoded = try JSONDecoder().decode(BLECommand.self, from: encoded)
        guard case let .channelUnavailable(decodedID) = decoded else {
            Issue.record("Expected channel-unavailable command")
            return
        }
        #expect(decodedID == channelID)
    }

    private func slide(_ id: String, order: UInt32) throws -> TourAssetDescriptor {
        try TourAssetDescriptor(
            assetID: id,
            kind: .slide,
            sha256: String(repeating: order == 0 ? "ab" : "cd", count: 32),
            byteLength: 100,
            order: order,
            mimeType: "image/jpeg"
        )
    }
}

private final class RecordingControlTransport: SessionControlTransport {
    struct SentMessage {
        let kind: SessionMessageKind
        let payload: Data
    }

    var isActive = false
    var hostIP: String?
    private var eventHandler: (@Sendable (SessionControlEvent) -> Void)?
    private(set) var sent: [SentMessage] = []
    private(set) var leaveFlushCount = 0

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {}

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        eventHandler = handler
    }

    func startGuide() { isActive = true }
    func startGuest() { isActive = true }

    func send(kind: SessionMessageKind, payload: Data) {
        sent.append(SentMessage(kind: kind, payload: payload))
    }

    func sendLeave() async {
        leaveFlushCount += 1
        sent.append(SentMessage(kind: .leave, payload: Data()))
    }

    func stop() { isActive = false }
    func clearSession() { stop() }

    func emit(_ event: SessionControlEvent) async {
        eventHandler?(event)
        await Task.yield()
    }

    func emitSnapshot(
        _ snapshot: PresentationSnapshotPayload,
        sessionID: UUID,
        guideID: UUID
    ) async throws {
        await emit(.envelopeReceived(try SessionEnvelope(
            lane: .control,
            kind: .presentationSnapshot,
            sequence: snapshot.stateVersion,
            sessionID: sessionID,
            senderID: guideID,
            payload: snapshot.encode()
        )))
    }

    func emitTarget(
        _ target: TargetSnapshotPayload,
        sessionID: UUID,
        guideID: UUID
    ) async throws {
        await emit(.envelopeReceived(try SessionEnvelope(
            lane: .control,
            kind: .targetSnapshot,
            sequence: target.stateVersion,
            sessionID: sessionID,
            senderID: guideID,
            payload: target.encode()
        )))
    }

    func emitVisualFocus(
        _ focus: VisualFocusSnapshotPayload,
        sessionID: UUID,
        guideID: UUID
    ) async throws {
        await emit(.envelopeReceived(try SessionEnvelope(
            lane: .control,
            kind: .visualFocusSnapshot,
            sequence: focus.stateVersion,
            sessionID: sessionID,
            senderID: guideID,
            payload: focus.encode()
        )))
    }
}

private func presentationCredential(_ sessionID: UUID) throws -> SessionCredential {
    try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
}
