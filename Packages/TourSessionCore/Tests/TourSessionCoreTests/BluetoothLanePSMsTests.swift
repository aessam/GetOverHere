import Foundation
import Testing
@testable import TourSessionCore

struct BluetoothLanePSMsTests {
    @Test func separatedMetadataFixture() throws {
        let record = try BluetoothLanePSMs(admission: 128, realtime: 129, control: 256, asset: 65535, metadata: 130)
        #expect(record.encode().lowercaseHex == "474f4c32008000810100ffff0082")
        #expect(try BluetoothLanePSMs.decode(record.encode()) == record)
        #expect(record.psm(for: .metadata) == 130)
        for count in 0..<14 {
            #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs.decode(record.encode().prefix(count)) }
        }
        #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs(admission: 128, realtime: 129, control: 256, asset: 65535, metadata: 128) }
        #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs(admission: 128, realtime: 129, control: 256, asset: 65535, metadata: 0) }
    }

    @Test func sharedFixtureAndLaneMapping() throws {
        let endpoints = try BluetoothLanePSMs(admission: 128, realtime: 129, control: 256, asset: 65535)
        #expect(endpoints.encode().lowercaseHex == "474f4c31008000810100ffff")
        #expect(try BluetoothLanePSMs.decode(endpoints.encode()) == endpoints)
        #expect(endpoints.psm(for: .metadata) == 128)
        #expect(endpoints.psm(for: .admission) == 128)
        #expect(endpoints.psm(for: .realtime) == 129)
        #expect(endpoints.psm(for: .control) == 256)
        #expect(endpoints.psm(for: .asset) == 65535)
        for index in UInt16(1)...100 {
            let record = try BluetoothLanePSMs(admission: index, realtime: index + 100,
                                              control: index + 200, asset: index + 300)
            #expect(try BluetoothLanePSMs.decode(record.encode()) == record)
        }
    }

    @Test func rejectsTruncatedUnknownDuplicateAndZeroEndpoints() throws {
        let bytes = try BluetoothLanePSMs(admission: 128, realtime: 129, control: 256, asset: 65535).encode()
        for count in 0..<bytes.count {
            #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs.decode(bytes.prefix(count)) }
        }
        #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs.decode(bytes + Data([0])) }
        var bad = bytes; bad[3] = 50
        #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs.decode(bad) }
        for offset in stride(from: 4, to: 12, by: 2) {
            bad = bytes; bad[offset] = 0; bad[offset + 1] = 0
            #expect(throws: RoomAdmissionError.self) { try BluetoothLanePSMs.decode(bad) }
        }
        #expect(throws: RoomAdmissionError.self) {
            try BluetoothLanePSMs(admission: 1, realtime: 1, control: 2, asset: 3)
        }
    }
}
