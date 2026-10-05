import Foundation
import Network
import Testing
@testable import GetOverHere

struct NearbyAwareFailureTests {
    @available(iOS 26.0, *)
    @Test func reportedNativeCodePreservesStageWithoutInventingACause() {
        let message = NearbyAwareFailure.message(for: NWError.wifiAware(-11992), during: .advertising)
        #expect(message.contains("advertising failed (Wi-Fi Aware -11992)"))
        #expect(message.contains("retry"))
        #expect(message.contains("mixed-platform Aware pairing is not implemented"))
    }

    @Test func unrelatedErrorsRetainDomainAndCodeButNotPrivateDescriptions() {
        let error = NSError(domain: "ExampleTransport", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "private peer identity"])
        let message = NearbyAwareFailure.message(for: error, during: .metadata)
        #expect(message.contains("room metadata failed (ExampleTransport 17)"))
        #expect(!message.contains("private peer identity"))
    }
}
