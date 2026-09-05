import Foundation
import TourSessionCore

@main
enum TourSessionCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            fail("usage: tour-session-swift fixture | encrypted-fixture | decode HEX[|HEX...] | decode-encrypted HEX | decode-audio HEX | audio-fixture | handshake | realtime-fixture | simulate COUNT | faults | playout | state | auth | recovery | focus")
        }

        switch command {
        case "room-guide", "room-guest":
            guard arguments.count == 3 else { fail("room-guide/room-guest requires UUID CODE (use - for open)") }
            guard let id = UUID(uuidString: arguments[1]) else { fail("invalid session UUID") }
            let code: String? = arguments[2] == "-" ? nil : arguments[2]
            func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            func receive() throws -> Data {
                guard let line = readLine() else { fail("admission input closed") }
                return try Data(hex: line)
            }
            if command == "room-guide" {
                let guide = RoomAdmission.Guide(sessionID: id, policy: try RoomAccessPolicy(sessionID: id, code: code))
                emit(guide.challenge.lowercaseHex)
                emit(try guide.reply(to: receive(), sessionCode: "23456789AB").lowercaseHex)
            } else {
                let guest = try RoomAdmission.Guest(challenge: receive(), sessionID: id, code: code)
                emit(guest.request.lowercaseHex)
                emit(try guest.open(receive()))
            }
        case "fixture":
            print(try TourSessionFixtures.helloEnvelope().encode().lowercaseHex)
        case "encrypted-fixture":
            print(try TourSessionFixtures.encryptedHelloFixture().encode().lowercaseHex)
        case "decode":
            guard arguments.count == 2 else { fail("decode requires one |-separated hex argument") }
            print(try TourSessionFixtures.describeEnvelopes(arguments[1]))
        case "decode-encrypted":
            guard arguments.count == 2 else { fail("decode-encrypted requires one hex argument") }
            print(try TourSessionFixtures.describeSealed(Data(hex: arguments[1])))
        case "decode-audio":
            guard arguments.count == 2 else { fail("decode-audio requires one hex argument") }
            print(try TourSessionFixtures.describeAudioFrame(Data(hex: arguments[1])))
        case "audio-fixture":
            print(try TourSessionFixtures.encodedAudioFixture().encode().lowercaseHex)
        case "handshake":
            print(try TourSessionFixtures.handshakeFixtureHex())
        case "realtime-fixture":
            print(try TourSessionFixtures.encryptedRealtimeFixture().encode().lowercaseHex)
        case "simulate":
            guard arguments.count == 2, let count = Int(arguments[1]), count >= 0 else {
                fail("simulate requires a non-negative integer")
            }
            print(TourSessionFixtures.simulateParticipants(count: count))
        case "faults":
            print(RealtimeSequenceAudit(sequences: [1, 2, 2, 5, 4, 7]).report)
        case "playout":
            print(try TourSessionFixtures.simulatePlayout())
        case "state":
            print(try TourSessionFixtures.stateFixtureHex())
        case "auth":
            print(try TourSessionFixtures.authenticationFixtureHex())
        case "recovery":
            print(try TourSessionFixtures.simulateRecovery())
        case "focus":
            print(TourSessionFixtures.simulateVisualFocus())
        default:
            fail("unknown command: \(command)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        Foundation.exit(2)
    }
}
