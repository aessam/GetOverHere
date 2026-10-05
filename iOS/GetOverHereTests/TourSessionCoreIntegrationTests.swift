import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

struct TourSessionCoreIntegrationTests {
    @Test("iOS target consumes the shared GOH2 contract")
    func appTargetUsesSharedContract() throws {
        #expect(TourSessionContract.majorVersion == 2)
        #expect(TourSessionContract.minorVersion == 1)
        let fixture = try TourSessionFixtures.helloEnvelope()
        #expect(try SessionEnvelope.decode(fixture.encode()) == fixture)
    }

    /// DSCN-8: measure one PBKDF2 derive on the simulator and assert only a 5 s sanity ceiling.
    @Test("Stretched credential derives within the sanity ceiling")
    func stretchedCredentialBudget() throws {
        #expect(SealedSessionEnvelope.majorVersion == 4)
        let clock = ContinuousClock()
        let start = clock.now
        _ = try SessionCredential.derive(shortCode: "23456789AB", sessionID: TourSessionFixtures.sessionID)
        let elapsed = clock.now - start
        print("PBKDF2 derive (simulator): \(elapsed)")
        #expect(elapsed < .seconds(5), "derive took \(elapsed)")
    }
}
