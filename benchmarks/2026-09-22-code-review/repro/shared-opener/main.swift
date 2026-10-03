import Foundation
import TourSessionCore
let session = UUID(), guestB = UUID(), streamB = UUID()
let cred = try SessionCredential.derive(shortCode: "ABCDEFGHJK", sessionID: session)
let guideShared = SessionFrameOpener(credential: cred)   // one opener per run, as in LocalSessionControlTransport
func env(_ seq: UInt64) throws -> SessionEnvelope {
    try SessionEnvelope(lane: .control, kind: .heartbeat, sequence: seq, sessionID: session, senderID: guestB, payload: Data())
}
// Honest guest B
let sealerB = SessionFrameSealer(credential: cred)
_ = try guideShared.open(sealerB.seal(try env(1), streamID: streamB))
// Admitted attacker A holds the same credential; forges B's scope at seq 10_000 on A's own socket.
let sealerA = SessionFrameSealer(credential: cred)
let forged = try sealerA.seal(try env(10_000), streamID: streamB)
print("forged opened:", (try? guideShared.open(forged)).map { "\($0)".prefix(8) } ?? "rejected")
// (A's handler then drops A for senderID mismatch, but window state already advanced.)
do { _ = try guideShared.open(sealerB.seal(try env(2), streamID: streamB)); print("B seq2 accepted") }
catch { print("B seq2 rejected:", error) }
