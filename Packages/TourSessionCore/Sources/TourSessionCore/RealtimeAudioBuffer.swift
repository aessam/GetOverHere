import Foundation

public enum RealtimeAudioBufferError: Error, Equatable {
    case invalidFrameByteCount(Int)
    case invalidFrameCapacity(target: Int, maximum: Int)
}

public struct PCMFrameAccumulator: Sendable {
    public let frameByteCount: Int
    private var bufferedBytes = Data()

    public init(frameByteCount: Int) throws {
        guard frameByteCount > 0 else {
            throw RealtimeAudioBufferError.invalidFrameByteCount(frameByteCount)
        }
        self.frameByteCount = frameByteCount
    }

    public var bufferedByteCount: Int {
        bufferedBytes.count
    }

    public mutating func append(_ bytes: Data) -> [Data] {
        guard !bytes.isEmpty else { return [] }
        bufferedBytes.append(bytes)

        var frames: [Data] = []
        frames.reserveCapacity(bufferedBytes.count / frameByteCount)
        while bufferedBytes.count >= frameByteCount {
            frames.append(Data(bufferedBytes.prefix(frameByteCount)))
            bufferedBytes.removeFirst(frameByteCount)
        }
        return frames
    }

    public mutating func reset() {
        bufferedBytes.removeAll(keepingCapacity: true)
    }
}

public struct SequencedEncodedAudioFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let payload: EncodedAudioFramePayload

    public init(sequence: UInt64, payload: EncodedAudioFramePayload) {
        self.sequence = sequence
        self.payload = payload
    }
}

public enum EncodedAudioFrameOfferResult: Equatable, Sendable {
    case accepted
    case duplicate
    case expired
    case capacityExceeded
}

/// One clock tick's playout decision (ADR-045): a playable frame, a single lost
/// sequence to conceal with one silence frame, or nothing to play yet.
public enum EncodedAudioPlayoutDecision: Equatable, Sendable {
    case frame(SequencedEncodedAudioFrame)
    case conceal(missingSequence: UInt64)
    case wait
}

public struct EncodedAudioJitterBuffer: Sendable {
    private struct BufferedFrame: Sendable {
        let payload: EncodedAudioFramePayload
        let localDeadlineNanoseconds: UInt64
    }

    public let targetFrameCount: Int
    public let maximumFrameCount: Int

    private var frames: [UInt64: BufferedFrame] = [:]
    private var expectedSequence: UInt64?
    private var hasStarted = false
    // Windowed minimum clock offset (FND-2): the baseline follows sender/receiver clock drift.
    // An all-tour minimum expired every frame once a fast guest clock drifted past the lifetime.
    private var currentWindowMinimumOffset: Int64?
    private var previousWindowMinimumOffset: Int64?
    private var offsetWindowStartNanoseconds: UInt64 = 0

    /// Each window spans this much receiver time; the baseline covers the last one to two windows.
    public static let clockOffsetWindowNanoseconds: UInt64 = 10_000_000_000

    public init(targetFrameCount: Int, maximumFrameCount: Int) throws {
        guard targetFrameCount > 0, maximumFrameCount >= targetFrameCount else {
            throw RealtimeAudioBufferError.invalidFrameCapacity(
                target: targetFrameCount,
                maximum: maximumFrameCount
            )
        }
        self.targetFrameCount = targetFrameCount
        self.maximumFrameCount = maximumFrameCount
    }

    public var bufferedFrameCount: Int {
        frames.count
    }

    public mutating func offer(
        _ frame: SequencedEncodedAudioFrame,
        nowNanoseconds: UInt64
    ) -> EncodedAudioFrameOfferResult {
        if frames[frame.sequence] != nil { return .duplicate }
        if hasStarted, let expectedSequence, frame.sequence < expectedSequence { return .duplicate }
        guard let deadline = localDeadline(
            for: frame.payload,
            receivedAtNanoseconds: nowNanoseconds
        ) else { return .expired }
        guard frames.count < maximumFrameCount else { return .capacityExceeded }

        frames[frame.sequence] = BufferedFrame(
            payload: frame.payload,
            localDeadlineNanoseconds: deadline
        )
        if !hasStarted {
            expectedSequence = min(expectedSequence ?? frame.sequence, frame.sequence)
        }
        return .accepted
    }

    /// Clock-driven drain. Called once per negotiated frame duration by the playout timer.
    /// A missing expected sequence while the buffer is below the target depth is concealed
    /// (one silence frame keeps the timeline); at or above the target depth the buffer resyncs
    /// to its oldest frame instead of waiting for a frame that is probably lost.
    public mutating func popForPlayout(nowNanoseconds: UInt64) -> EncodedAudioPlayoutDecision {
        discardExpiredFrames(nowNanoseconds: nowNanoseconds)
        guard !frames.isEmpty else { return .wait }

        if !hasStarted {
            guard frames.count >= targetFrameCount else { return .wait }
            hasStarted = true
            expectedSequence = frames.keys.min()
        }

        guard let sequence = expectedSequence else { return .wait }
        if let buffered = frames.removeValue(forKey: sequence) {
            expectedSequence = sequence == UInt64.max ? nil : sequence + 1
            return .frame(SequencedEncodedAudioFrame(sequence: sequence, payload: buffered.payload))
        }
        if frames.count >= targetFrameCount, let next = frames.keys.min(),
           let buffered = frames.removeValue(forKey: next) {
            expectedSequence = next == UInt64.max ? nil : next + 1
            return .frame(SequencedEncodedAudioFrame(sequence: next, payload: buffered.payload))
        }
        expectedSequence = sequence == UInt64.max ? nil : sequence + 1
        return .conceal(missingSequence: sequence)
    }

    public mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        expectedSequence = nil
        hasStarted = false
        currentWindowMinimumOffset = nil
        previousWindowMinimumOffset = nil
        offsetWindowStartNanoseconds = 0
    }

    private mutating func clockOffsetBaseline(observedOffset: Int64, receivedAtNanoseconds: UInt64) -> Int64 {
        let window = Self.clockOffsetWindowNanoseconds
        // Receiver time before the window start never rotates, matching Kotlin's signed elapsed time.
        let elapsed: UInt64? = receivedAtNanoseconds >= offsetWindowStartNanoseconds
            ? receivedAtNanoseconds - offsetWindowStartNanoseconds : nil
        if let current = currentWindowMinimumOffset, let elapsed, elapsed >= window {
            // A window older than the one just closed is stale after a long silence.
            previousWindowMinimumOffset = elapsed < 2 * window ? current : nil
            currentWindowMinimumOffset = observedOffset
            offsetWindowStartNanoseconds = receivedAtNanoseconds
        } else if let current = currentWindowMinimumOffset {
            currentWindowMinimumOffset = min(current, observedOffset)
        } else {
            previousWindowMinimumOffset = nil
            currentWindowMinimumOffset = observedOffset
            offsetWindowStartNanoseconds = receivedAtNanoseconds
        }
        let windowMinimum = currentWindowMinimumOffset ?? observedOffset
        return previousWindowMinimumOffset.map { min($0, windowMinimum) } ?? windowMinimum
    }

    private mutating func discardExpiredFrames(nowNanoseconds: UInt64) {
        frames = frames.filter { $0.value.localDeadlineNanoseconds > nowNanoseconds }
    }

    /// Maps the sender's monotonic capture timeline to receiver-local time.
    /// Delay above the recent minimum clock offset consumes frame lifetime.
    private mutating func localDeadline(
        for payload: EncodedAudioFramePayload,
        receivedAtNanoseconds: UInt64
    ) -> UInt64? {
        guard let received = Int64(exactly: receivedAtNanoseconds),
              let captured = Int64(exactly: payload.capturedAtNanoseconds) else {
            return nil
        }
        let (observedOffset, offsetOverflow) = received.subtractingReportingOverflow(captured)
        guard !offsetOverflow else { return nil }

        let baseline = clockOffsetBaseline(observedOffset: observedOffset, receivedAtNanoseconds: receivedAtNanoseconds)
        let (excessDelay, delayOverflow) = observedOffset.subtractingReportingOverflow(baseline)
        guard !delayOverflow, excessDelay >= 0 else { return nil }

        let lifetime = payload.expiresAtNanoseconds - payload.capturedAtNanoseconds
        let delay = UInt64(excessDelay)
        guard delay < lifetime else { return nil }
        let remaining = lifetime - delay
        let (deadline, deadlineOverflow) = receivedAtNanoseconds.addingReportingOverflow(remaining)
        return deadlineOverflow ? UInt64.max : deadline
    }
}
