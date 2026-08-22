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
}
