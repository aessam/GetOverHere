import Foundation
import TourSessionCore
let cfg = try SessionAudioCodecConfiguration(codec: .opus, sampleRate: 16_000, channelCount: 1, frameDurationMilliseconds: 20, bitRate: 20_000)
var jb = try EncodedAudioJitterBuffer(targetFrameCount: 3, maximumFrameCount: 13)
var t: UInt64 = 1_000_000_000
@MainActor func step(_ seq: UInt64) -> (EncodedAudioFrameOfferResult, Bool) {
    let p = try! EncodedAudioFramePayload(configuration: cfg, capturedAtNanoseconds: t, expiresAtNanoseconds: t + 500_000_000, encodedBytes: Data([1]))
    let r = jb.offer(SequencedEncodedAudioFrame(sequence: seq, payload: p), nowNanoseconds: t + 5_000_000)
    var played = false
    if case .frame = jb.popForPlayout(nowNanoseconds: t + 5_000_000) { played = true }
    t += 20_000_000
    return (r, played)
}
for s in 0..<90_000 { _ = step(UInt64(s)) } // 30 minutes on old stream
var dup = 0, played = 0
for s in 0..<3_000 { let (r, p) = step(UInt64(s)); if r == .duplicate { dup += 1 }; if p { played += 1 } } // 60 s after replacement, seq restarts at 0
print("after replacement: 3000 frames offered, duplicate=\(dup), played=\(played)")
