import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Renderer readiness reporting", .serialized)
struct AudioReadinessServiceTests {
    @Test @MainActor
    func guideCountsOnlyConnectedGuestsLatestRendererReport() async throws {
        let transport = LifecycleControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID(), guideID = UUID(), guestID = UUID()
        service.configureSession(sessionID: sessionID, participantID: guideID, displayName: "Guide",
            platform: .iOS, credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID))
        try service.startGuide(deckID: sessionID)
        defer { service.clearSession() }
        func report(_ status: AudioReadinessStatus, revision: UInt64, sender: UUID) throws {
            transport.emit(.envelopeReceived(try SessionEnvelope(lane: .control, kind: .audioStatus,
                sequence: revision, sessionID: sessionID, senderID: sender,
                payload: AudioReadinessPayload(status: status, revision: revision).encode())))
        }
        transport.emit(.guestJoined(ParticipantSession(participantID: guestID, connectionID: "guest",
            displayName: "Guest", role: .guest, platform: .android)))
        try await waitUntil { service.connectedGuestCount == 1 }
        #expect(service.audioReadyGuestCount == 0)
        try report(.playing, revision: 1, sender: guestID)
        try await waitUntil { service.audioReadyGuestCount == 1 }
        try report(.interrupted, revision: 2, sender: guestID)
        try await waitUntil { service.audioReadyGuestCount == 0 }
        try report(.playing, revision: 1, sender: guestID) // stale status cannot restore readiness
        try report(.playing, revision: 10, sender: UUID()) // not an admitted participant
        await Task.yield()
        #expect(service.audioReadyGuestCount == 0)
        try report(.playing, revision: 3, sender: guestID)
        try await waitUntil { service.audioReadyGuestCount == 1 }
        transport.emit(.guestDisconnected(participantID: guestID))
        try await waitUntil { service.connectedGuestCount == 0 }
        #expect(service.audioReadyGuestCount == 0)
    }

    @Test @MainActor
    func guestReportsActualStateOnlyAfterAuthenticatedControlConnects() async throws {
        let transport = LifecycleControlTransport()
        let service = TourControlService(transport: transport)
        let sessionID = UUID()
        service.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Guest",
            platform: .iOS, credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID))
        service.startGuest(hostIP: "127.0.0.1")
        defer { service.clearSession() }
        service.reportAudioReadiness(.playing)
        #expect(transport.sent.isEmpty)
        transport.emit(.connected)
        try await waitUntil { transport.sent.count == 1 }
        let first = try AudioReadinessPayload.decode(transport.sent[0].payload)
        #expect(first.status == .playing)
        service.reportAudioReadiness(.interrupted)
        let second = try AudioReadinessPayload.decode(transport.sent[1].payload)
        #expect(second.status == .interrupted && second.revision > first.revision)
        service.reportAudioReadiness(.interrupted)
        #expect(transport.sent.count == 2, "Unchanged runtime state does not flood the control lane")
    }

    private enum Timeout: Error { case expired }
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Timeout.expired }
            await Task.yield()
        }
    }
}
