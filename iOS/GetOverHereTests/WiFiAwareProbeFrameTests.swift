import Foundation
import Testing
@testable import GetOverHere

struct WiFiAwareProbeFrameTests {
    @Test func wireFormatMatchesCrossPlatformFixture() throws {
        let frame = WiFiAwareProbeFrame(
            kind: .probe,
            sequence: 0x0102_0304_0506_0708,
            sentAtNanoseconds: 0x1112_1314_1516_1718,
            payload: Data([0xAA, 0xBB, 0xCC])
        )

        let expected = Data([
            0x47, 0x4F, 0x48, 0x31,
            0x01, 0x02, 0x00, 0x00,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x00, 0x00, 0x00, 0x03,
            0xAA, 0xBB, 0xCC,
        ])

        #expect(frame.encoded() == expected)
        #expect(try WiFiAwareProbeFrame.decode(expected) == frame)
    }

    @Test func rejectsTruncatedPayload() {
        var bytes = WiFiAwareProbeFrame(
            kind: .hello,
            sequence: 1,
            sentAtNanoseconds: 2,
            payload: Data([3, 4])
        ).encoded()
        bytes.removeLast()

        #expect(throws: WiFiAwareProbeFrame.DecodeError.invalidPayloadLength(expected: 2, actual: 1)) {
            try WiFiAwareProbeFrame.decode(bytes)
        }
    }
}
