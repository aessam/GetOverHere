import Foundation
import Testing
@testable import TourSessionCore

struct NearbyLaneRequestTests {
    @Test func sharedFixtureAndEveryLaneRoundtrip() throws {
        let room = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let request = try NearbyLaneRequest(lane: .admission, roomID: room)
        #expect(request.encode().map { String(format: "%02x", $0) }.joined() ==
            "474f44310400112233445566778899aabbccddeeff")
        for lane in NearbyLaneRequest.Lane.allCases {
            for _ in 0..<100 {
                let value = try NearbyLaneRequest(lane: lane,
                    roomID: lane == .metadata ? NearbyLaneRequest.metadataRoomID : UUID())
                #expect(try NearbyLaneRequest.decode(value.encode()) == value)
            }
        }
        #expect(Set(NearbyLaneRequest.Lane.allCases.compactMap(\.localPort)) == Set(50_000...50_003))
        #expect(NearbyLaneRequest.servicePort == 50_004)
    }

    @Test func rejectsMalformedAndUnscopedApplicationRequests() throws {
        let good = try NearbyLaneRequest(lane: .control, roomID: UUID()).encode()
        for length in 0..<good.count {
            #expect(throws: (any Error).self) { try NearbyLaneRequest.decode(good.prefix(length)) }
        }
        #expect(throws: (any Error).self) { try NearbyLaneRequest.decode(good + Data([0])) }
        var bad = good; bad[4] = 255
        #expect(throws: (any Error).self) { try NearbyLaneRequest.decode(bad) }
        bad = good; bad[3] = 50
        #expect(throws: (any Error).self) { try NearbyLaneRequest.decode(bad) }
        #expect(throws: (any Error).self) {
            try NearbyLaneRequest(lane: .admission, roomID: NearbyLaneRequest.metadataRoomID)
        }
        #expect(throws: (any Error).self) { try NearbyLaneRequest(lane: .metadata, roomID: UUID()) }
    }
}
