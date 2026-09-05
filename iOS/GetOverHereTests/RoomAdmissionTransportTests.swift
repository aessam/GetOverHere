import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite(.serialized)
struct RoomAdmissionTransportTests {
    @Test(arguments: [false, true])
    @MainActor
    func discoveryRoundtrip(locked: Bool) throws {
        let announce = BLECommand.ChannelAnnounce(channelID: UUID().uuidString, channelName: "Room",
            createdBy: UUID().uuidString, audioQuality: .standard, wifiSSID: nil, audioHostIP: "127.0.0.1",
            roomAdmissionVersion: 1, isRoomLocked: locked)
        let data = try JSONEncoder().encode(BLECommand.channelAnnounce(announce: announce))
        guard case let .channelAnnounce(decoded) = try JSONDecoder().decode(BLECommand.self, from: data) else {
            Issue.record("Discovery did not decode as channelAnnounce")
            return
        }
        #expect(decoded.roomAdmissionVersion == 1)
        #expect(decoded.isRoomLocked == locked)
        #expect(decoded.channelID == announce.channelID)
        let legacy = Data(#"{"channelAnnounce":{"channelID":"legacy","channelName":"Room","createdBy":"guide","audioQuality":"standard"}}"#.utf8)
        guard case let .channelAnnounce(old) = try JSONDecoder().decode(BLECommand.self, from: legacy) else {
            Issue.record("Legacy discovery rejected")
            return
        }
        #expect(old.roomAdmissionVersion == nil)
        #expect(old.isRoomLocked == nil)
    }

    @Test func lockEditUnlockPreservesMediaSecret() throws {
        let id = UUID()
        let transport = RoomAdmissionTransport(port: 56003)
        defer { transport.stop() }
        try transport.start(sessionID: id, sessionCode: "23456789AB")
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, code: nil) == "23456789AB")
        try transport.update(policy: RoomAccessPolicy(sessionID: id, code: "1234"))
        #expect(throws: (any Error).self) { try transport.join(host: "127.0.0.1", sessionID: id, code: nil) }
        #expect(throws: (any Error).self) { try transport.join(host: "127.0.0.1", sessionID: id, code: "wrong") }
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, code: "1234") == "23456789AB")
        try transport.update(policy: RoomAccessPolicy(sessionID: id, code: "Edited!"))
        #expect(throws: (any Error).self) { try transport.join(host: "127.0.0.1", sessionID: id, code: "1234") }
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, code: "Edited!") == "23456789AB")
        try transport.update(policy: RoomAccessPolicy(sessionID: id, code: nil))
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, code: nil) == "23456789AB")
    }
}
