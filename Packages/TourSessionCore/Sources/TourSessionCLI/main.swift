import Foundation
import TourSessionCore

@main
enum TourSessionCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            fail("usage: tour-session-swift fixture | decode HEX | simulate COUNT | faults | state | auth | recovery | focus")
        }

        switch command {
        case "fixture":
            print(try TourSessionFixtures.helloEnvelope().encode().lowercaseHex)
        case "decode":
            guard arguments.count == 2 else { fail("decode requires one hex argument") }
            print(try TourSessionFixtures.describeHello(Data(hex: arguments[1])))
        case "simulate":
            guard arguments.count == 2, let count = Int(arguments[1]), count >= 0 else {
                fail("simulate requires a non-negative integer")
            }
            print(TourSessionFixtures.simulateParticipants(count: count))
        case "faults":
            print(RealtimeSequenceAudit(sequences: [1, 2, 2, 5, 4, 7]).report)
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
