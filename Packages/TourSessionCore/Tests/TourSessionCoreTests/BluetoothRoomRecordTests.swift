import Foundation
import Testing
@testable import TourSessionCore

struct BluetoothRoomRecordTests {
    @Test func sharedFixtureAndRoundtrips() throws {
        let room = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let guide = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
        let fixture = BluetoothRoomRecord(roomID: room, guideID: guide, name: "Tour", isAndroid: true, isLocked: true)
        #expect(try fixture.encode().map { String(format: "%02x", $0) }.joined() ==
            "474f52310300112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f7572")
        let v2 = BluetoothRoomRecord(roomID: room, guideID: guide, name: "Tour", isAndroid: true, isLocked: true,
                                     admissionVersion: 2)
        #expect(try v2.encode().lowercaseHex ==
            "474f52320300112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f7572")
        #expect(try BluetoothRoomRecord.decode(v2.encode()) == v2)
        for index in 1...100 {
            let record = BluetoothRoomRecord(roomID: room, guideID: guide,
                name: String(repeating: "ج🌍", count: index % 50 + 1), isAndroid: index % 2 == 0, isLocked: index % 3 == 0,
                admissionVersion: index % 2 + 1)
            #expect(try BluetoothRoomRecord.decode(record.encode()) == record)
        }
        let maximum = BluetoothRoomRecord(roomID: room, guideID: guide, name: String(repeating: "x", count: 400), isAndroid: false, isLocked: false)
        #expect(try BluetoothRoomRecord.decode(maximum.encode()) == maximum)
    }
    @Test func malformedRecordsFailClosed() throws {
        let value = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false, isLocked: false)
        let bytes = try value.encode()
        for count in 0..<bytes.count { #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bytes.prefix(count)) } }
        var bad = bytes; bad[4] = 4
        #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bad) }
        bad = bytes; bad[39] = 255
        #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bad) }
        #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bytes + Data([0])) }
        for version in [0, 3, 255] {
            #expect(throws: (any Error).self) {
                try BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Tour", isAndroid: false,
                                        isLocked: false, admissionVersion: version).encode()
            }
            bad = bytes; bad[3] = UInt8(version)
            #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bad) }
        }
    }
}
