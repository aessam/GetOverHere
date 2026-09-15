import Foundation
import Testing
import TourSessionCore

struct GatewaySecurityReviewTests {
    @Test func freshOfferSurvivesTenSecondCompanionClockSkew() throws {
        let offer = try GatewayPairingMessage(role: .offer, pairingID: UUID(), roomID: UUID(), guideID: UUID(),
            expiresAtMilliseconds: 1_120_000, certificateFingerprint: Data(repeating: 1, count: 32),
            guideKeyFingerprint: Data(repeating: 2, count: 32), offerCertificateFingerprint: Data(repeating: 1, count: 32),
            host: "192.0.2.1", port: 50104)
        // Same cross-platform case: scan after 3s, companion clock 10s behind.
        try offer.validateReceivedOffer(nowMilliseconds: 993_000)
    }
}
