import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// ADR-081 T5 (QST-1): with a bridge assigned, other-platform guests connect directly only as bridge or standby.
@Suite("Direct guest admission (ADR-081 T5)", .serialized)
struct DirectGuestAdmissionTests {
    let bridge = UUID(), standby = UUID()

    func assignment(standbys: [UUID]) throws -> BridgeAssignmentPayload {
        try BridgeAssignmentPayload(generation: 1, bridgeID: bridge, bridgePlatform: .android,
                                    leaseExpiresAtMilliseconds: .max, standbyIDs: standbys)
    }

    @Test func everyoneIsAdmittedWithoutABridge() {
        let policy = DirectGuestAdmission(guidePlatform: .iOS)
        #expect(policy.admits(participantID: UUID(), platform: .android, relayCapable: false))
    }

    @Test func bridgeAndTwoStandbysOnlyThenRefuse() throws {
        let policy = DirectGuestAdmission(guidePlatform: .iOS)
        policy.update(assignment: try assignment(standbys: [standby]))
        #expect(policy.admits(participantID: bridge, platform: .android, relayCapable: true))
        #expect(policy.admits(participantID: standby, platform: .android, relayCapable: true))
        #expect(!policy.admits(participantID: UUID(), platform: .android, relayCapable: false), "non-relay guests use the island")
        let second = UUID()
        #expect(policy.admits(participantID: second, platform: .android, relayCapable: true), "a free standby slot")
        policy.update(assignment: try assignment(standbys: [standby, second]))
        #expect(!policy.admits(participantID: UUID(), platform: .android, relayCapable: true), "standbys are full")
        #expect(policy.admits(participantID: UUID(), platform: .iOS, relayCapable: false), "same-platform guests are unaffected")
    }

    @Test func guestsAdmittedEarlierAreReadmitted() throws {
        let policy = DirectGuestAdmission(guidePlatform: .iOS)
        let early = UUID()
        #expect(policy.admits(participantID: early, platform: .android, relayCapable: false))
        policy.update(assignment: try assignment(standbys: [standby, UUID()]))
        #expect(policy.admits(participantID: early, platform: .android, relayCapable: false), "a reconnect is never stranded")
    }

    @Test("A refused guest never gets a welcome on the guide's control lane")
    @MainActor
    func refusedGuestNeverJoins() async throws {
        let port: UInt16 = 50_061
        let guide = LocalSessionControlTransport(port: port)
        let guest = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        let joined = EventLog<SessionControlEvent>(), guestEvents = EventLog<SessionControlEvent>()
        defer { guest.stop(); guide.stop() }
        let policy = DirectGuestAdmission(guidePlatform: .iOS)
        policy.update(assignment: try assignment(standbys: [standby, UUID()]))
        guide.setDirectGuestAdmission(policy)
        guide.configureGuideAuthentication(.legacyFixture)
        guide.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Guide", platform: .iOS, credential: credential)
        guide.setEventHandler { event in Task { @MainActor in joined.items.append(event) } }
        try guide.startGuide()
        guest.hostIP = "127.0.0.1"
        guest.configureGuideAuthentication(.legacyFixture)
        guest.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Pixel", platform: .android, credential: credential)
        guest.setEventHandler { event in Task { @MainActor in guestEvents.items.append(event) } }
        guest.startGuest()
        let deadline = Date().addingTimeInterval(5)
        while guestEvents.items.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!guestEvents.items.isEmpty, "the refused guest sees its lane end")
        #expect(!guestEvents.items.contains { if case .connected = $0 { true } else { false } })
        #expect(!joined.items.contains { if case .guestJoined = $0 { true } else { false } })
    }
}
