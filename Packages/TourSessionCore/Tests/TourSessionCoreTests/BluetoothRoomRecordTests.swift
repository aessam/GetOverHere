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
    @Test("A tour pack advert follows the name, is pinned, and stays within 439 bytes (ADR-080)")
    func packAdvert() throws {
        let room = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let guide = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
        let pack = TourPackAdvert(packID: UUID(uuidString: "6F1C5C6A-0000-4000-8000-0000000000A1")!,
                                  manifestVersion: 0x0102030405060708)
        let record = BluetoothRoomRecord(roomID: room, guideID: guide, name: "Tour", isAndroid: false, isLocked: true,
                                         admissionVersion: 2, pack: pack)
        #expect(try record.encode().lowercaseHex == "474f52320600112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f75726f1c5c6a0000400080000000000000a10102030405060708")
        #expect(try BluetoothRoomRecord.decode(record.encode()) == record)
        // 39 + 376 + 24 = 439: the longest name that still fits with an advert.
        let longest = BluetoothRoomRecord(roomID: room, guideID: guide, name: String(repeating: "x", count: 376),
                                          isAndroid: true, isLocked: false, pack: pack)
        #expect(try BluetoothRoomRecord.decode(longest.encode()) == longest)
        #expect(throws: (any Error).self) {
            try BluetoothRoomRecord(roomID: room, guideID: guide, name: String(repeating: "x", count: 377),
                                    isAndroid: true, isLocked: false, pack: pack).encode()
        }
        let bytes = try record.encode()
        for count in 0 ..< bytes.count {
            #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bytes.prefix(count)) }
        }
        var noAdvert = bytes; noAdvert[4] &= ~4 // flag cleared: the 24 trailing bytes become a bad name length
        #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(noAdvert) }
    }

    @Test("A relay host section follows the pack advert, is pinned, and both fit in 439 bytes (ADR-081 W3)")
    func relayHost() throws {
        let room = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let guide = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
        let pack = TourPackAdvert(packID: UUID(uuidString: "6F1C5C6A-0000-4000-8000-0000000000A1")!, manifestVersion: 2)
        let host = RelayHostAdvert(hostID: UUID(uuidString: "6F1C5C6A-0000-4000-8000-0000000000B1")!, bridgeGeneration: 7)
        let record = BluetoothRoomRecord(roomID: room, guideID: guide, name: "Tour", isAndroid: true, isLocked: false,
                                         admissionVersion: 2, pack: pack, relayHost: host)
        #expect(try record.encode().lowercaseHex == "474f52320d00112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f75726f1c5c6a0000400080000000000000a100000000000000026f1c5c6a0000400080000000000000b10000000000000007")
        #expect(try BluetoothRoomRecord.decode(record.encode()) == record)
        let hostOnly = BluetoothRoomRecord(roomID: room, guideID: guide, name: "Tour", isAndroid: false, isLocked: true,
                                           relayHost: host)
        #expect(try BluetoothRoomRecord.decode(hostOnly.encode()) == hostOnly)
        // 39 + 352 + 24 + 24 = 439.
        let longest = BluetoothRoomRecord(roomID: room, guideID: guide, name: String(repeating: "x", count: 352),
                                          isAndroid: true, isLocked: false, pack: pack, relayHost: host)
        #expect(try BluetoothRoomRecord.decode(longest.encode()) == longest)
        #expect(throws: (any Error).self) {
            try BluetoothRoomRecord(roomID: room, guideID: guide, name: String(repeating: "x", count: 353),
                                    isAndroid: true, isLocked: false, pack: pack, relayHost: host).encode()
        }
        var bytes = try record.encode()
        bytes[4] &= ~8 // flag cleared: the trailing host bytes become a bad name length
        #expect(throws: (any Error).self) { try BluetoothRoomRecord.decode(bytes) }
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
