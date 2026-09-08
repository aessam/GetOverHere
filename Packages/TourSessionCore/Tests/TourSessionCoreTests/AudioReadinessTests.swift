import Foundation
import Testing
@testable import TourSessionCore

@Suite("Audio readiness wire contract")
struct AudioReadinessTests {
    @Test func everyStateAndRevisionRoundTrips() throws {
        for status in AudioReadinessStatus.allCases {
            for revision: UInt64 in [0, 1, 0x0102030405060708, .max] {
                let value = AudioReadinessPayload(status: status, revision: revision)
                #expect(try AudioReadinessPayload.decode(value.encode()) == value)
            }
        }
        #expect(AudioReadinessPayload(status: .playing, revision: 0x0102030405060708).encode()
            == Data([1, 2, 1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(SessionMessageKind.audioStatus.requiredLane == .control)
    }

    @Test func rejectsUnknownAndNonCanonicalPayloads() {
        let valid = AudioReadinessPayload(status: .playing, revision: 1).encode()
        for length in 0..<valid.count {
            #expect(throws: (any Error).self) { try AudioReadinessPayload.decode(Data(valid.prefix(length))) }
        }
        #expect(throws: (any Error).self) { try AudioReadinessPayload.decode(valid + Data([0])) }
        for (offset, value) in [(0, UInt8(2)), (1, UInt8(0)), (1, UInt8(5))] {
            var invalid = valid
            invalid[offset] = value
            #expect(throws: (any Error).self) { try AudioReadinessPayload.decode(invalid) }
        }
    }
}
