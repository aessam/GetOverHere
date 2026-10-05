import Foundation
import TourSessionCore
// Guest clock runs `ppm` faster than the guide's capture clock. Offers each 20 ms frame
// 5 ms after capture (guest time) and reports the first minute at which offers stop playing.
let cfg = try SessionAudioCodecConfiguration(codec: .opus, sampleRate: 16_000, channelCount: 1, frameDurationMilliseconds: 20, bitRate: 20_000)
for ppm in [100.0, 40.0, -40.0] {
    var jb = try EncodedAudioJitterBuffer(targetFrameCount: 3, maximumFrameCount: 13)
    var firstSilentMinute: Double? = nil
    var played = 0
    let frames = 4 * 3600 * 50 // 4 hours
    for s in 0..<frames {
        let captured = 1_000_000_000 + UInt64(s) * 20_000_000
        let guestNow = UInt64(Double(captured + 5_000_000) * (1 + ppm / 1_000_000))
        let p = try EncodedAudioFramePayload(configuration: cfg, capturedAtNanoseconds: captured, expiresAtNanoseconds: captured + 500_000_000, encodedBytes: Data([1]))
        _ = jb.offer(SequencedEncodedAudioFrame(sequence: UInt64(s), payload: p), nowNanoseconds: guestNow)
        if case .frame = jb.popForPlayout(nowNanoseconds: guestNow) { played += 1 }
        else if firstSilentMinute == nil, s > 100 { firstSilentMinute = Double(s) / 50 / 60 }
    }
    print("ppm=\(ppm) played=\(played)/\(frames) firstSilentAfterMin=\(firstSilentMinute.map { String(format: "%.1f", $0) } ?? "never")")
}
