import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Bounded pre-encode audio", .serialized)
struct AudioEncodeAdmissionTests {
    @Test("A blocked encoder leaves at most eight queued submissions and drops oldest work")
    func overflowIsBounded() async throws {
        let f = try Fixture(mode: .blockFirst)
        defer { f.stop() }
        f.submit(0)
        try await waitUntil { f.provider.isBlocked }
        for value in 1...20 { f.submit(UInt8(value)) }
        #expect(f.processor.pendingCount == 8)
        #expect(f.processor.droppedCount == 12)
        f.provider.release.signal()
        try await waitUntil { f.frames.count == 9 }
        #expect(try f.payloads.map { $0.encodedBytes.first! } == [0] + Array(13...20).map(UInt8.init))
        #expect(f.provider.createdCount == 2, "overflow must recreate the encoder rather than mix across a gap")
        let sealed = try f.sealedFrames
        #expect(Set(sealed.map(\.streamID)).count == 1)
        let sequences = try f.envelopes.map(\.sequence)
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Queued and active stale work is dropped, then fresh input recovers")
    func delayedEncoderCannotRestampOldAudio() async throws {
        let f = try Fixture(mode: .blockFirst)
        defer { f.stop() }
        f.submit(1)
        try await waitUntil { f.provider.isBlocked }
        f.submit(2)
        f.clock.advance(milliseconds: 150)
        f.provider.release.signal()
        try await waitUntil { f.processor.droppedCount >= 2 }
        #expect(f.frames.isEmpty)
        f.submit(3)
        try await waitUntil { f.frames.count == 1 }
        #expect(try f.payloads[0].encodedBytes == Data(repeating: 3, count: 4))
        #expect(try f.payloads[0].capturedAtNanoseconds == f.clock.wall)
    }

    @Test("Buffered codec output keeps the oldest supplied timestamp, never the latest input time")
    func nilOutputKeepsOldestTimestamp() async throws {
        let f = try Fixture(mode: .bufferFirst)
        defer { f.stop() }
        let original = f.clock.wall
        f.submit(1)
        try await waitUntil { f.provider.encodedCount == 1 }
        f.clock.advance(milliseconds: 40)
        f.submit(2)
        try await waitUntil { f.frames.count == 1 }
        #expect(try f.payloads[0].capturedAtNanoseconds == original)
        #expect(try f.payloads[0].encodedBytes == Data(repeating: 1, count: 4))
    }

    @Test("A codec's delayed buffered output expires and is flushed before recovery")
    func nilThenDelayedOutputCannotEscapeExpiry() async throws {
        let f = try Fixture(mode: .bufferThenBlock)
        defer { f.stop() }
        f.submit(1)
        try await waitUntil { f.provider.encodedCount == 1 }
        f.clock.advance(milliseconds: 100)
        f.submit(2)
        try await waitUntil { f.provider.isBlocked }
        f.clock.advance(milliseconds: 50)
        f.provider.release.signal()
        try await waitUntil { f.processor.droppedCount == 1 }
        #expect(f.frames.isEmpty)
        f.submit(3)
        try await waitUntil { f.frames.count == 1 }
        #expect(try f.payloads[0].encodedBytes == Data(repeating: 3, count: 4))
        #expect(f.provider.createdCount == 2)
    }

    @Test("Only the first mixed frame inherits a partial input timestamp")
    func partialFrameTimestampSpansArePreserved() async throws {
        let f = try Fixture(mode: .passthrough)
        defer { f.stop() }
        let first = f.clock.wall
        f.processor.submit(pcm: Data([1, 1]), destinations: [.opus: []])
        try await waitUntil { f.provider.createdCount == 1 }
        f.clock.advance(milliseconds: 20)
        let second = f.clock.wall
        f.processor.submit(pcm: Data(repeating: 2, count: 8), destinations: [.opus: []])
        try await waitUntil { f.frames.count == 2 }
        f.clock.advance(milliseconds: 20)
        f.processor.submit(pcm: Data([3, 3]), destinations: [.opus: []])
        try await waitUntil { f.frames.count == 3 }
        #expect(try f.payloads.map(\.capturedAtNanoseconds) == [first, second, second])
        #expect(try f.payloads.map(\.encodedBytes) == [Data([1, 1, 2, 2]), Data([2, 2, 2, 2]), Data([2, 2, 3, 3])])
    }

    @Test("Expired partial PCM is discarded before fresh PCM is packetized")
    func expiredPartialCannotContaminateFreshFrame() async throws {
        let f = try Fixture(mode: .passthrough)
        defer { f.stop() }
        f.processor.submit(pcm: Data([1, 1]), destinations: [.opus: []])
        try await waitUntil { f.provider.createdCount == 1 }
        f.clock.advance(milliseconds: 150)
        f.submit(2)
        try await waitUntil { f.frames.count == 1 }
        #expect(try f.payloads[0].encodedBytes == Data(repeating: 2, count: 4))
        #expect(f.processor.droppedCount == 1)
    }

    @Test("Stop clears pending input, discards an in-progress encode, and leaves replacement output intact")
    func stopAndReplacementAreIndependent() async throws {
        let old = try Fixture(mode: .blockFirst)
        let replacement = try Fixture(mode: .passthrough)
        defer { old.stop(); replacement.stop() }
        old.submit(1)
        try await waitUntil { old.provider.isBlocked }
        old.submit(2)
        old.processor.stop(); old.processor.stop()
        #expect(old.processor.pendingCount == 0)
        replacement.submit(3)
        try await waitUntil { replacement.frames.count == 1 }
        old.provider.release.signal()
        try await waitUntil { old.provider.destroyedCount == 1 }
        #expect(old.frames.isEmpty)
        #expect(try replacement.payloads[0].encodedBytes == Data(repeating: 3, count: 4))
        old.submit(4)
        #expect(old.processor.pendingCount == 0)
    }

    @Test("Malformed or oversized PCM is rejected before native encoder allocation")
    func invalidInputIsBounded() throws {
        let f = try Fixture(mode: .passthrough)
        defer { f.stop() }
        for data in [Data(), Data([1]), Data(count: 32_002)] {
            f.processor.submit(pcm: data, destinations: [.opus: []])
        }
        #expect(f.processor.pendingCount == 0)
        #expect(f.processor.droppedCount == 3)
        #expect(f.provider.createdCount == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum TestError: Error { case timeout }

    private final class Fixture {
        let clock = TestClock()
        let provider: TestProvider
        let processor: UDPAudioPlane.BroadcastProcessor
        private let recorder = FrameRecorder()
        private let credential: SessionCredential
        private let verifier: GuideFrameVerifier

        init(mode: TestProvider.Mode) throws {
            let session = UUID(), guide = UUID()
            credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: session)
            let signer = GuideFrameSigner(sessionID: session, guideID: guide)
            verifier = try GuideFrameVerifier(pinnedPublicKey: signer.publicKey, sessionID: session, guideID: guide)
            provider = TestProvider(mode: mode)
            let clock = clock, recorder = recorder
            processor = UDPAudioPlane.BroadcastProcessor(
                configuration: .init(sessionID: session, participantID: guide, displayName: "Guide", platform: .iOS, credential: credential),
                codecProvider: provider, frameLifetimeNanoseconds: 500_000_000,
                authentication: .guide(signer), monotonicClock: { clock.monotonic }, wallClock: { clock.wall },
                deliver: { frame, _ in recorder.append(frame) })
        }

        func submit(_ byte: UInt8) { processor.submit(pcm: Data(repeating: byte, count: 4), destinations: [.opus: []]) }
        func stop() { processor.stop(); provider.release.signal() }
        var frames: [Data] { recorder.snapshot }
        var sealedFrames: [SealedSessionEnvelope] {
            get throws { try frames.map { try verifier.verify($0) } }
        }
        var envelopes: [SessionEnvelope] {
            get throws {
                let opener = SessionFrameOpener(credential: credential)
                return try sealedFrames.map {
                    switch try opener.open($0) {
                    case .opened(let envelope): return envelope
                    case .duplicate: throw TestError.timeout
                    }
                }
            }
        }
        var payloads: [EncodedAudioFramePayload] {
            get throws { try envelopes.map { try EncodedAudioFramePayload.decode($0.payload) } }
        }
    }
}

nonisolated private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: UInt64 = 0
    var monotonic: UInt64 { lock.withLock { 1_000_000 + elapsed } }
    var wall: UInt64 { lock.withLock { 10_000_000_000 + elapsed } }
    func advance(milliseconds: UInt64) { lock.withLock { elapsed += milliseconds * 1_000_000 } }
}

nonisolated private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    func append(_ data: Data) { lock.withLock { frames.append(data) } }
    var snapshot: [Data] { lock.withLock { frames } }
}

nonisolated private final class TestProvider: RealtimeAudioCodecProviderInterface, @unchecked Sendable {
    enum Mode { case passthrough, blockFirst, bufferFirst, bufferThenBlock }
    let mode: Mode
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var created = 0, encoded = 0, destroyed = 0
    private var blocked = false
    var createdCount: Int { lock.withLock { created } }
    var encodedCount: Int { lock.withLock { encoded } }
    var destroyedCount: Int { lock.withLock { destroyed } }
    var isBlocked: Bool { lock.withLock { blocked } }

    init(mode: Mode) { self.mode = mode }
    func sessionCapabilities() -> SessionCapabilities { [.opusEncoder] }
    func makeDecoder(configuration: SessionAudioCodecConfiguration) throws -> any RealtimeAudioDecoderInterface {
        throw NativeRealtimeAudioCodecError.unsupportedCodec(.opus)
    }
    func makeEncoder(codec: SessionAudioCodec) throws -> any RealtimeAudioEncoderInterface {
        let index = lock.withLock { let index = created; created += 1; return index }
        return try TestEncoder(provider: self, mode: index == 0 ? mode : .passthrough)
    }
    func didEncode() { lock.withLock { encoded += 1 } }
    func didDestroy() { lock.withLock { destroyed += 1 } }
    func block() throws {
        lock.withLock { blocked = true }
        defer { lock.withLock { blocked = false } }
        guard release.wait(timeout: .now() + 5) == .success else {
            throw NativeRealtimeAudioCodecError.conversionFailed(status: -1, detail: "Test release timed out")
        }
    }
}

nonisolated private final class TestEncoder: RealtimeAudioEncoderInterface {
    let codec = SessionAudioCodec.opus
    let inputPCMByteCount = 4
    let configuration: SessionAudioCodecConfiguration
    private let provider: TestProvider
    private let mode: TestProvider.Mode
    private var calls = 0
    private var buffered: Data?

    init(provider: TestProvider, mode: TestProvider.Mode) throws {
        self.provider = provider; self.mode = mode
        configuration = try SessionAudioCodecConfiguration(codec: .opus, sampleRate: 16_000,
            channelCount: 1, frameDurationMilliseconds: 20, bitRate: 20_000)
    }
    deinit { provider.didDestroy() }
    func encode(pcm16LittleEndian: Data) throws -> NativeEncodedAudioPacket? {
        calls += 1; provider.didEncode()
        if mode == .blockFirst, calls == 1 { try provider.block() }
        if mode == .bufferFirst || mode == .bufferThenBlock {
            if calls == 1 { buffered = pcm16LittleEndian; return nil }
            if mode == .bufferThenBlock, calls == 2 { try provider.block() }
            let packet = buffered!
            buffered = pcm16LittleEndian
            return NativeEncodedAudioPacket(configuration: configuration, bytes: packet)
        }
        return NativeEncodedAudioPacket(configuration: configuration, bytes: pcm16LittleEndian)
    }
}
