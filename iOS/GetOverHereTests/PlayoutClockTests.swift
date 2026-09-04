import Foundation
import os
import Testing
import TourSessionCore
@testable import GetOverHere

/// Transport-level proof for ADR-045: the clock, not frame arrival, drives playout; a single lost
/// frame becomes exactly one silence frame of the negotiated duration; a decoder failure is
/// reported once. The timer is never started here; `tick()` is driven with an injected clock.
@Suite("Clocked playout")
struct PlayoutClockTests {
    private static let fixedNow: UInt64 = 1_000_000

    @Test("A gap is concealed with one silence frame and playout resumes on the next frame")
    func gapIsConcealedWithSilence() throws {
        let decoder = try FakePlayoutDecoder()
        let emitted = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let clock = try PlayoutClock(
            decoder: decoder,
            clock: { Self.fixedNow },
            emit: { pcm in emitted.withLock { $0.append(pcm) } },
            onDecodeFailure: { failures.withLock { $0 += 1 } }
        )
        defer { clock.stop() }

        for sequence: UInt64 in [1, 2, 3, 5] {
            let frame = SequencedEncodedAudioFrame(
                sequence: sequence,
                payload: try decoder.payload(byte: UInt8(sequence))
            )
            #expect(clock.offer(frame, nowNanoseconds: Self.fixedNow) == .accepted)
        }
        for _ in 0 ..< 5 { clock.tick() }

        // 16 kHz * 20 ms / 1000 * 1 channel * 2 bytes = 640 bytes of PCM16 silence.
        #expect(clock.silenceFrame.count == 640)
        #expect(clock.silenceFrame == Data(count: 640))
        #expect(emitted.withLock { $0 } == [Data([1]), Data([2]), Data([3]), Data(count: 640), Data([5])])
        #expect(failures.withLock { $0 } == 0)
        #expect(decoder.decodeCount == 4)
    }

    @Test("A throwing decoder reports failure exactly once and stops the clock")
    func decodeFailureReportsOnce() throws {
        let decoder = try FakePlayoutDecoder(failing: true)
        let emitted = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let clock = try PlayoutClock(
            decoder: decoder,
            clock: { Self.fixedNow },
            emit: { pcm in emitted.withLock { $0.append(pcm) } },
            onDecodeFailure: { failures.withLock { $0 += 1 } }
        )
        defer { clock.stop() }

        for sequence: UInt64 in [1, 2, 3] {
            let frame = SequencedEncodedAudioFrame(
                sequence: sequence,
                payload: try decoder.payload(byte: UInt8(sequence))
            )
            #expect(clock.offer(frame, nowNanoseconds: Self.fixedNow) == .accepted)
        }
        for _ in 0 ..< 3 { clock.tick() }

        #expect(failures.withLock { $0 } == 1)
        #expect(emitted.withLock { $0 }.isEmpty)
        #expect(decoder.decodeCount == 1)
    }
}

private enum FakeDecodeError: Error {
    case rejected
}

private final class FakePlayoutDecoder: RealtimeAudioDecoderInterface, @unchecked Sendable {
    let configuration: SessionAudioCodecConfiguration
    private let failing: Bool
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    var decodeCount: Int { counter.withLock { $0 } }

    init(failing: Bool = false) throws {
        self.failing = failing
        configuration = try SessionAudioCodecConfiguration(
            codec: .opus,
            sampleRate: 16_000,
            channelCount: 1,
            frameDurationMilliseconds: 20,
            bitRate: 20_000
        )
    }

    func payload(byte: UInt8) throws -> EncodedAudioFramePayload {
        try EncodedAudioFramePayload(
            configuration: configuration,
            capturedAtNanoseconds: 0,
            expiresAtNanoseconds: 500_000_000,
            encodedBytes: Data([byte])
        )
    }

    func decode(packet: Data) throws -> Data? {
        counter.withLock { $0 += 1 }
        if failing { throw FakeDecodeError.rejected }
        return packet
    }
}
