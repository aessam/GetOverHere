import Foundation
import CryptoKit
import Testing
@testable import TourSessionCore

struct RoomAdmissionTests {
    @Test func leadingZeroSharedSecretKeepsFixedWidthThroughHKDF() throws {
        // Private scalars 1 and 379: x(379*G) begins with 00. Same vector in Kotlin.
        let peer = try Data(hex: "04005543894af3d00ed7d740abdbd75c96b06877b787db5f70eea78b90a8d7c00abb4c85a3d8ea29efaafa24406912dd84d5b14dc32bf656ef6c6bd58a5d943f92")
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        let derived = try RoomAdmission.derive(key, peer, Data(repeating: 0, count: 32), Data())
        #expect(derived.withUnsafeBytes { Data($0).lowercaseHex } == "1652d7207df35c849397c233a68b03323308bd4dcd2f50e20ab8323fea0bd015")
        let v2 = try RoomAdmission.derive(key, peer, Data(repeating: 0, count: 32), Data(),
                                          domain: "GetOverHere/room-admission/v2")
        #expect(v2.withUnsafeBytes { Data($0).lowercaseHex } == "e6c7820134e8240ee5ab4f70d589cc9a4e29531739e7301a50e24057f06a53fd")
    }

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
