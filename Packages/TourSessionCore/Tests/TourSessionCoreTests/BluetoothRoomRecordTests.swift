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
        for index in 1...100 {
            let record = BluetoothRoomRecord(roomID: room, guideID: guide,
                name: String(repeating: "ج🌍", count: index % 50 + 1), isAndroid: index % 2 == 0, isLocked: index % 3 == 0)
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
    }
}
