import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Local target guidance")
struct LocalGuidanceServiceTests {
    @Test("Guidance uses local position without changing the shared target")
    func guidanceUsesOnlyLocalPosition() throws {
        let target = try TargetSnapshotPayload(
            stateVersion: 1,
            targetID: UUID(),
            latitudeE7: 377_749_000,
            longitudeE7: -1_224_194_000,
            label: "Gate",
            isVisible: true
        )

        let guidance = LocalTargetGuidance.calculate(
            latitude: 37.7740,
            longitude: -122.4194,
            headingDegrees: 90,
            target: target
        )

        #expect(abs(guidance.distanceMeters - 100.1) < 1)
        #expect(abs(guidance.targetBearingDegrees) < 1)
        #expect(abs((guidance.relativeArrowDegrees ?? 0) - 270) < 1)
        #expect(target.latitudeE7 == 377_749_000)
        #expect(target.longitudeE7 == -1_224_194_000)
    }
}
