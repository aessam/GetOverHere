import Foundation
import Testing
@testable import TourSessionCore

struct RoomAdmissionTests {
    @Test(arguments: [nil, "1234", "My-Tour!42", String(repeating: "a", count: 64)] as [String?])
    func roundtrip(code: String?) throws {
        let id = UUID()
        let guide = RoomAdmission.Guide(sessionID: id, policy: try RoomAccessPolicy(sessionID: id, code: code))
        let guest = try RoomAdmission.Guest(challenge: guide.challenge, sessionID: id, code: code)
        let reply = try guide.reply(to: guest.request, sessionCode: "23456789AB")
        #expect(try guest.open(reply) == "23456789AB")
        var tampered = reply
        tampered[20] ^= 1
        #expect(throws: (any Error).self) { try guest.open(tampered) }
    }

    @Test func rejectsWrongCodeAndReplay() throws {
        let id = UUID()
        let policy = try RoomAccessPolicy(sessionID: id, code: "1234")
        let guide = RoomAdmission.Guide(sessionID: id, policy: policy)
        #expect(throws: (any Error).self) { try RoomAdmission.Guest(challenge: guide.challenge, sessionID: id, code: nil) }
        let wrong = try RoomAdmission.Guest(challenge: guide.challenge, sessionID: id, code: "5678")
        #expect(throws: (any Error).self) { try guide.reply(to: wrong.request, sessionCode: "23456789AB") }
        let guest = try RoomAdmission.Guest(challenge: guide.challenge, sessionID: id, code: "1234")
        let next = RoomAdmission.Guide(sessionID: id, policy: policy)
        #expect(throws: (any Error).self) { try next.reply(to: guest.request, sessionCode: "23456789AB") }
        #expect(throws: (any Error).self) { try RoomAdmission.Guest(challenge: guide.challenge, sessionID: UUID(), code: "1234") }
    }

    @Test(arguments: ["", "123", "ab cd", "é123", String(repeating: "x", count: 65)])
    func invalidCodes(code: String) {
        #expect(!RoomAccessPolicy.isValidCode(code))
    }
}
