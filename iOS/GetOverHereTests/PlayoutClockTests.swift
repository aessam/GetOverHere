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

    @Test("Stopped run callbacks cannot target a replacement run")
    func runCallbackSnapshotsAreIndependent() {
        let oldPCM = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let newPCM = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let oldEvents = OSAllocatedUnfairLock(initialState: 0)
        let newEvents = OSAllocatedUnfairLock(initialState: 0)
        let old = AudioRunCallbacks(audio: { data in oldPCM.withLock { $0.append(data) } },
            session: { _ in oldEvents.withLock { $0 += 1 } })
        old.emitAudio(Data([1]))
        old.emitSession(.failed("old active run"))
        old.stop()
        let replacement = AudioRunCallbacks(audio: { data in newPCM.withLock { $0.append(data) } },
            session: { _ in newEvents.withLock { $0 += 1 } })
        old.emitAudio(Data([2]))
        old.emitSession(.authenticationFailed("stale run"))
        replacement.emitAudio(Data([3]))
        replacement.emitSession(.failed("replacement run"))
        old.stop()
        #expect(oldPCM.withLock { $0 } == [Data([1])])
        #expect(newPCM.withLock { $0 } == [Data([3])])
        #expect(oldEvents.withLock { $0 } == 1 && newEvents.withLock { $0 } == 1)
        replacement.stop()
        replacement.emitAudio(Data([4]))
        replacement.emitSession(.failed("stopped replacement"))
        #expect(newPCM.withLock { $0 } == [Data([3])])
        #expect(newEvents.withLock { $0 } == 1)
    }

    @Test("A decoder finishing after stop cannot deliver PCM or report into the next run", arguments: [false, true])
    func stoppedClockDiscardsInProgressDecode(failsAfterRelease: Bool) throws {
        let decoder = try BlockingPlayoutDecoder(failsAfterRelease: failsAfterRelease)
        let emitted = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchSemaphore(value: 0)
        let clock = try PlayoutClock(decoder: decoder, clock: { Self.fixedNow },
            emit: { pcm in emitted.withLock { $0.append(pcm) } },
            onDecodeFailure: { failures.withLock { $0 += 1 } })
        defer { clock.stop(); decoder.release.signal() }
        for sequence: UInt64 in [1, 2, 3] {
            let payload = try EncodedAudioFramePayload(configuration: decoder.configuration,
                capturedAtNanoseconds: 0, expiresAtNanoseconds: 500_000_000,
                encodedBytes: Data([UInt8(sequence)]))
            #expect(clock.offer(SequencedEncodedAudioFrame(sequence: sequence, payload: payload),
                nowNanoseconds: Self.fixedNow) == .accepted)
        }
        // The decoder blocks only on this dedicated queue. No production thread is joined by stop.
        DispatchQueue.global(qos: .userInitiated).async { clock.tick(); finished.signal() }
        try #require(decoder.entered.wait(timeout: .now() + 3) == .success)
        clock.stop()
        decoder.release.signal()
        try #require(finished.wait(timeout: .now() + 3) == .success)
        #expect(emitted.withLock { $0 }.isEmpty)
        #expect(failures.withLock { $0 } == 0)
    }

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
    case rejected, releaseTimedOut
}

private final class BlockingPlayoutDecoder: RealtimeAudioDecoderInterface, @unchecked Sendable {
    let configuration: SessionAudioCodecConfiguration
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let failsAfterRelease: Bool

    init(failsAfterRelease: Bool) throws {
        self.failsAfterRelease = failsAfterRelease
        configuration = try SessionAudioCodecConfiguration(codec: .opus, sampleRate: 16_000,
            channelCount: 1, frameDurationMilliseconds: 20, bitRate: 20_000)
    }

    func decode(packet: Data) throws -> Data? {
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw FakeDecodeError.releaseTimedOut }
        if failsAfterRelease { throw FakeDecodeError.rejected }
        return packet
    }
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
