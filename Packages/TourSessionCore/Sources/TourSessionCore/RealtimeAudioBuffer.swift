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
    private var minimumClockOffsetNanoseconds: Int64?

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

    public mutating func popReady(nowNanoseconds: UInt64) -> SequencedEncodedAudioFrame? {
        discardExpiredFrames(nowNanoseconds: nowNanoseconds)
        guard !frames.isEmpty else { return nil }

        if !hasStarted {
            guard frames.count >= targetFrameCount else { return nil }
            hasStarted = true
            expectedSequence = frames.keys.min()
        }

        guard var sequence = expectedSequence else { return nil }
        if frames[sequence] == nil {
            guard frames.count >= targetFrameCount, let next = frames.keys.min() else { return nil }
            sequence = next
        }
        guard let buffered = frames.removeValue(forKey: sequence) else { return nil }
        expectedSequence = sequence == UInt64.max ? nil : sequence + 1
        return SequencedEncodedAudioFrame(sequence: sequence, payload: buffered.payload)
    }

    public mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        expectedSequence = nil
        hasStarted = false
        minimumClockOffsetNanoseconds = nil
    }

    private mutating func discardExpiredFrames(nowNanoseconds: UInt64) {
        frames = frames.filter { $0.value.localDeadlineNanoseconds > nowNanoseconds }
    }

    /// Maps the sender's monotonic capture timeline to receiver-local time.
    /// Delay above the minimum observed clock offset consumes frame lifetime.
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

        let baseline = min(minimumClockOffsetNanoseconds ?? observedOffset, observedOffset)
        minimumClockOffsetNanoseconds = baseline
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
