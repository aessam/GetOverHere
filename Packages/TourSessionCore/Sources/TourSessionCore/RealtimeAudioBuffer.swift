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
    public let targetFrameCount: Int
    public let maximumFrameCount: Int

    private var frames: [UInt64: EncodedAudioFramePayload] = [:]
    private var expectedSequence: UInt64?
    private var hasStarted = false

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
        guard !frame.payload.isExpired(atNanoseconds: nowNanoseconds) else { return .expired }
        if frames[frame.sequence] != nil { return .duplicate }
        if hasStarted, let expectedSequence, frame.sequence < expectedSequence { return .duplicate }
        guard frames.count < maximumFrameCount else { return .capacityExceeded }

        frames[frame.sequence] = frame.payload
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
        guard let payload = frames.removeValue(forKey: sequence) else { return nil }
        expectedSequence = sequence == UInt64.max ? nil : sequence + 1
        return SequencedEncodedAudioFrame(sequence: sequence, payload: payload)
    }

    public mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        expectedSequence = nil
        hasStarted = false
    }

    private mutating func discardExpiredFrames(nowNanoseconds: UInt64) {
        frames = frames.filter { !$0.value.isExpired(atNanoseconds: nowNanoseconds) }
    }
}
