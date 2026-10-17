import Foundation
import Testing
@testable import TourSessionCore

@Suite("Batched realtime audio (ADR-075)")
struct AudioBatchTests {
    static let batchHex = "0100003e8001001400004e20000000044f70757303000000003b9aca000000000059682f0000000004f8fffe00000000003ccbf700000000005a995c0000000004f8fffe01000000003dfd2400000000005bca890000000004f8fffe02"

    private func opus(_ csd: Data = Data()) throws -> SessionAudioCodecConfiguration {
        try SessionAudioCodecConfiguration(codec: .opus, sampleRate: 16_000, channelCount: 1,
                                           frameDurationMilliseconds: 20, bitRate: 20_000, codecSpecificData: csd)
    }

    private func frame(_ sequence: UInt64, configuration: SessionAudioCodecConfiguration? = nil, bytes: Int = 4) throws -> SequencedEncodedAudioFrame {
        let captured = 1_000_000_000 + sequence * 20_000_000
        return SequencedEncodedAudioFrame(sequence: sequence, payload: try EncodedAudioFramePayload(
            configuration: try configuration ?? opus(), capturedAtNanoseconds: captured,
            expiresAtNanoseconds: captured + 500_000_000, encodedBytes: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: bytes)))
    }

    @Test("Batch fixture bytes are pinned and round-trip")
    func fixtureRoundTrip() throws {
        let fixture = try TourSessionFixtures.encodedAudioBatchFixture()
        #expect(fixture.encode().lowercaseHex == Self.batchHex)
        #expect(try EncodedAudioBatchPayload.decode(Data(hex: Self.batchHex)) == fixture)
        #expect(SessionMessageKind.audioBatch.rawValue == 0x11)
        #expect(SessionMessageKind.audioBatch.requiredLane == .realtime)
        #expect(SessionCapabilities.opusBatchDecoder.rawValue == 1 << 4)
    }

    @Test("Malformed batches are rejected")
    func rejectsMalformedBatches() throws {
        var bytes = [UInt8](try Data(hex: Self.batchHex))
        let countOffset = 1 + 4 + 1 + 2 + 4 + 4 + 4
        #expect(bytes[countOffset] == 3)
        for invalid: UInt8 in [0, 9] {
            bytes[countOffset] = invalid
            #expect(throws: EncodedAudioFrameError.invalidBatchCount(Int(invalid))) {
                try EncodedAudioBatchPayload.decode(Data(bytes))
            }
        }
        let valid = try Data(hex: Self.batchHex)
        #expect(throws: SessionProtocolError.self) { try EncodedAudioBatchPayload.decode(valid + Data([0])) }
        #expect(throws: (any Error).self) { try EncodedAudioBatchPayload.decode(valid.dropLast()) }
        #expect(throws: EncodedAudioFrameError.batchConfigurationMismatch) {
            try EncodedAudioBatchPayload(frames: [try frame(0).payload, try frame(1, configuration: opus(Data([1]))).payload])
        }
        #expect(throws: EncodedAudioFrameError.invalidBatchCount(0)) { try EncodedAudioBatchPayload(frames: []) }
    }

    @Test("Batcher closes on count, sequence gap, configuration change, deadline and discard")
    func batcherRules() throws {
        var batcher = try AudioFrameBatcher(maximumFrameCount: 3, maximumWaitNanoseconds: 40)
        #expect(try batcher.append(frame(10), nowNanoseconds: 100).isEmpty)
        #expect(try batcher.append(frame(11), nowNanoseconds: 120).isEmpty)
        let full = try batcher.append(frame(12), nowNanoseconds: 130)
        #expect(full.count == 1 && full[0].firstSequence == 10)
        #expect(full[0].sequencedFrames.map(\.sequence) == [10, 11, 12])
        #expect(batcher.pendingFrameCount == 0 && batcher.flushDeadlineNanoseconds == nil)

        #expect(try batcher.append(frame(13), nowNanoseconds: 200).isEmpty)
        let gap = try batcher.append(frame(15), nowNanoseconds: 210)
        #expect(gap.map(\.firstSequence) == [13] && gap[0].payload.frames.count == 1)
        let changed = try batcher.append(frame(16, configuration: opus(Data([7]))), nowNanoseconds: 215)
        #expect(changed.map(\.firstSequence) == [15])

        #expect(batcher.flushDeadlineNanoseconds == 255)
        #expect(try batcher.flushIfDue(nowNanoseconds: 254) == nil)
        #expect(try batcher.flushIfDue(nowNanoseconds: 255)?.firstSequence == 16)

        _ = try batcher.append(frame(17), nowNanoseconds: 300)
        batcher.discard()
        #expect(try batcher.flushAll() == nil)
        #expect(throws: EncodedAudioFrameError.invalidBatchCount(9)) {
            try AudioFrameBatcher(maximumFrameCount: 9, maximumWaitNanoseconds: 0)
        }
    }

    @Test("Opus is negotiated only with batch support; otherwise AAC-LC")
    func negotiation() throws {
        let sender: SessionCapabilities = [.opusEncoder, .aacLCEncoder]
        #expect(try SessionAudioCodecNegotiation.preferredCodec(sender: sender, receiver: [.opusDecoder, .opusBatchDecoder, .aacLCDecoder]) == .opus)
        #expect(try SessionAudioCodecNegotiation.preferredCodec(sender: sender, receiver: [.opusDecoder, .aacLCDecoder]) == .aacLC)
        #expect(throws: EncodedAudioFrameError.noCommonCodec) {
            try SessionAudioCodecNegotiation.preferredCodec(sender: sender, receiver: [.opusDecoder])
        }
    }

    @Test("Three 20 ms frames sealed and signed as one batch cost at most 55% of three singles")
    func batchingHalvesWireBytes() throws {
        let credential = try TourSessionFixtures.fixtureCredential()
        let configuration = try opus(Data(repeating: 0x4F, count: 19))
        let frames = try (0..<3).map { try frame(UInt64($0), configuration: configuration, bytes: 50) }
        // Per packet outside the sealed envelope: 4 B length prefix + 8 B GOS1 header + 64 B signature.
        let perPacket = 4 + 8 + 64
        let sealer = SessionFrameSealer(credential: credential)
        let stream = UUID()
        let singles = try frames.map { frame in
            try sealer.seal(SessionEnvelope(lane: .realtime, kind: .audioFrame, sequence: frame.sequence,
                sessionID: TourSessionFixtures.sessionID, senderID: TourSessionFixtures.guideID,
                payload: frame.payload.encode()), streamID: stream).encode().count + perPacket
        }.reduce(0, +)
        let batchSealer = SessionFrameSealer(credential: credential)
        let batch = try batchSealer.seal(SessionEnvelope(lane: .realtime, kind: .audioBatch, sequence: 0,
            sessionID: TourSessionFixtures.sessionID, senderID: TourSessionFixtures.guideID,
            payload: EncodedAudioBatchPayload(frames: frames.map(\.payload)).encode()), streamID: stream).encode().count + perPacket
        #expect(Double(batch) <= 0.55 * Double(singles), "batch \(batch) B vs singles \(singles) B")
    }

    @Test("Playout sizing covers two Opus bursts and keeps AAC-LC at 60 ms")
    func playoutSizing() throws {
        #expect(RealtimeAudioPlayoutSizing.frameCounts(for: try opus()) == (6, 13))
        let aac = try SessionAudioCodecConfiguration(codec: .aacLC, sampleRate: 16_000, channelCount: 1,
                                                     frameDurationMilliseconds: 64, bitRate: 16_000)
        #expect(RealtimeAudioPlayoutSizing.frameCounts(for: aac) == (1, 4))
    }

    /// Batches of three arrive every 60 ms with deterministic jitter; playout pops every 20 ms.
    private func stallsAfterWarmUp(target: Int, maximum: Int, jitterScale: Int64 = 1) throws -> Int {
        var buffer = try EncodedAudioJitterBuffer(targetFrameCount: target, maximumFrameCount: maximum)
        let jitter: [Int64] = [0, 6, -4, 9, 2, -6, 8, 0]
        var arrivals: [(at: UInt64, frame: SequencedEncodedAudioFrame)] = []
        for batch in 0..<200 {
            let lastCapture = Int64(1_000_000_000 + (batch * 3 + 2) * 20_000_000)
            let at = UInt64(lastCapture + 10_000_000 + jitter[batch % jitter.count] * jitterScale * 1_000_000)
            for index in 0..<3 { arrivals.append((at, try frame(UInt64(batch * 3 + index), bytes: 1))) }
        }
        var next = 0
        var started = false
        var stalls = 0
        var now: UInt64 = 1_000_000_000 + 7_000_000
        while now < 1_000_000_000 + 11_000_000_000 {
            while next < arrivals.count, arrivals[next].at <= now {
                _ = buffer.offer(arrivals[next].frame, nowNanoseconds: arrivals[next].at)
                next += 1
            }
            switch buffer.popForPlayout(nowNanoseconds: now) {
            case .frame: started = true
            case .wait, .conceal: if started { stalls += 1 }
            }
            now += 20_000_000
        }
        return stalls
    }

    @Test("Burst arrival plays without stalls at the batched target; the old 60 ms target glitches")
    func burstArrivalPlayout() throws {
        let (target, maximum) = RealtimeAudioPlayoutSizing.frameCounts(for: try opus())
        // Jitter peaks of 9-45 ms bracket the measured Bluetooth idle RTT spread (p95 - p50, Sept 10).
        for scale: Int64 in 1...5 {
            #expect(try stallsAfterWarmUp(target: target, maximum: maximum, jitterScale: scale) == 0, "scale \(scale)")
        }
        // At 18 ms peaks the old target starves once, then recovers with the latency it lost.
        #expect(try stallsAfterWarmUp(target: 3, maximum: 13, jitterScale: 2) > 0)
    }
}
