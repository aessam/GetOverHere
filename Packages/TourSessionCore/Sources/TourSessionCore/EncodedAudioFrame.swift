import Foundation

public struct SessionCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let opusEncoder = SessionCapabilities(rawValue: 1 << 0)
    public static let opusDecoder = SessionCapabilities(rawValue: 1 << 1)
    public static let aacLCEncoder = SessionCapabilities(rawValue: 1 << 2)
    public static let aacLCDecoder = SessionCapabilities(rawValue: 1 << 3)
    /// The receiver accepts `audioBatch` envelopes. Opus is sent only in batches (ADR-075).
    public static let opusBatchDecoder = SessionCapabilities(rawValue: 1 << 4)
}

public enum SessionAudioCodec: UInt8, CaseIterable, Sendable {
    case opus = 1
    case aacLC = 2
}

public enum EncodedAudioFrameError: Error, Equatable, CustomStringConvertible {
    case unsupportedCodec(UInt8)
    case invalidSampleRate(UInt32)
    case invalidChannelCount(UInt8)
    case invalidFrameDuration(UInt16)
    case invalidBitRate(UInt32)
    case invalidExpiry(capturedAt: UInt64, expiresAt: UInt64)
    case encodedPayloadTooLarge(Int)
    case noCommonCodec
    case invalidBatchCount(Int)
    case batchConfigurationMismatch

    public var description: String {
        switch self {
        case let .unsupportedCodec(raw): "unsupported audio codec \(raw)"
        case let .invalidSampleRate(value): "invalid audio sample rate \(value)"
        case let .invalidChannelCount(value): "invalid audio channel count \(value)"
        case let .invalidFrameDuration(value): "invalid audio frame duration \(value) ms"
        case let .invalidBitRate(value): "invalid audio bit rate \(value)"
        case let .invalidExpiry(capturedAt, expiresAt):
            "audio expiry \(expiresAt) must be after capture \(capturedAt)"
        case let .encodedPayloadTooLarge(count): "encoded audio payload is too large: \(count) bytes"
        case .noCommonCodec: "sender and receiver have no common native audio codec"
        case let .invalidBatchCount(count): "invalid audio batch frame count \(count)"
        case .batchConfigurationMismatch: "audio batch frames use different codec configurations"
        }
    }
}

public struct SessionAudioCodecConfiguration: Equatable, Sendable {
    public let codec: SessionAudioCodec
    public let sampleRate: UInt32
    public let channelCount: UInt8
    public let frameDurationMilliseconds: UInt16
    public let bitRate: UInt32
    public let codecSpecificData: Data

    public init(
        codec: SessionAudioCodec,
        sampleRate: UInt32,
        channelCount: UInt8,
        frameDurationMilliseconds: UInt16,
        bitRate: UInt32,
        codecSpecificData: Data = Data()
    ) throws {
        guard sampleRate > 0 else { throw EncodedAudioFrameError.invalidSampleRate(sampleRate) }
        guard channelCount > 0 else { throw EncodedAudioFrameError.invalidChannelCount(channelCount) }
        guard frameDurationMilliseconds > 0 else {
            throw EncodedAudioFrameError.invalidFrameDuration(frameDurationMilliseconds)
        }
        guard bitRate > 0 else { throw EncodedAudioFrameError.invalidBitRate(bitRate) }
        guard codecSpecificData.count <= Int(UInt32.max) else {
            throw EncodedAudioFrameError.encodedPayloadTooLarge(codecSpecificData.count)
        }
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.bitRate = bitRate
        self.codecSpecificData = codecSpecificData
    }
}

public struct EncodedAudioFramePayload: Equatable, Sendable {
    public static let fixedHeaderSize = 36

    public let configuration: SessionAudioCodecConfiguration
    public let capturedAtNanoseconds: UInt64
    public let expiresAtNanoseconds: UInt64
    public let encodedBytes: Data

    public init(
        configuration: SessionAudioCodecConfiguration,
        capturedAtNanoseconds: UInt64,
        expiresAtNanoseconds: UInt64,
        encodedBytes: Data
    ) throws {
        guard expiresAtNanoseconds > capturedAtNanoseconds else {
            throw EncodedAudioFrameError.invalidExpiry(
                capturedAt: capturedAtNanoseconds,
                expiresAt: expiresAtNanoseconds
            )
        }
        guard encodedBytes.count <= Int(UInt32.max) else {
            throw EncodedAudioFrameError.encodedPayloadTooLarge(encodedBytes.count)
        }
        self.configuration = configuration
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.expiresAtNanoseconds = expiresAtNanoseconds
        self.encodedBytes = encodedBytes
    }

    public func isExpired(atNanoseconds now: UInt64) -> Bool {
        now >= expiresAtNanoseconds
    }

    public func encode() -> Data {
        var writer = BinaryWriter(capacity: Self.fixedHeaderSize + encodedBytes.count)
        writer.append(configuration.codec.rawValue)
        writer.append(configuration.sampleRate)
        writer.append(configuration.channelCount)
        writer.append(configuration.frameDurationMilliseconds)
        writer.append(configuration.bitRate)
        writer.append(UInt32(configuration.codecSpecificData.count))
        writer.append(configuration.codecSpecificData)
        writer.append(capturedAtNanoseconds)
        writer.append(expiresAtNanoseconds)
        writer.append(UInt32(encodedBytes.count))
        writer.append(encodedBytes)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> EncodedAudioFramePayload {
        var reader = BinaryReader(data: data)
        let codecRaw = try reader.readUInt8()
        guard let codec = SessionAudioCodec(rawValue: codecRaw) else {
            throw EncodedAudioFrameError.unsupportedCodec(codecRaw)
        }
        let sampleRate = try reader.readUInt32()
        let channelCount = try reader.readUInt8()
        let frameDuration = try reader.readUInt16()
        let bitRate = try reader.readUInt32()
        let codecSpecificDataLength = Int(try reader.readUInt32())
        let codecSpecificData = try reader.readData(count: codecSpecificDataLength)
        let configuration = try SessionAudioCodecConfiguration(
            codec: codec,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameDurationMilliseconds: frameDuration,
            bitRate: bitRate,
            codecSpecificData: codecSpecificData
        )
        let capturedAt = try reader.readUInt64()
        let expiresAt = try reader.readUInt64()
        let encodedLength = Int(try reader.readUInt32())
        guard reader.remaining == encodedLength else {
            throw SessionProtocolError.invalidPayloadLength(expected: encodedLength, actual: reader.remaining)
        }
        return try EncodedAudioFramePayload(
            configuration: configuration,
            capturedAtNanoseconds: capturedAt,
            expiresAtNanoseconds: expiresAt,
            encodedBytes: reader.readData(count: encodedLength)
        )
    }
}

public enum SessionAudioCodecNegotiation {
    public static func preferredCodec(
        sender: SessionCapabilities,
        receiver: SessionCapabilities
    ) throws -> SessionAudioCodec {
        // Opus travels only in batches; a receiver without batch support falls back to AAC-LC.
        if sender.contains(.opusEncoder), receiver.contains([.opusDecoder, .opusBatchDecoder]) {
            return .opus
        }
        if sender.contains(.aacLCEncoder), receiver.contains(.aacLCDecoder) {
            return .aacLC
        }
        throw EncodedAudioFrameError.noCommonCodec
    }
}

/// Consecutive frames of one codec configuration sealed as one envelope (ADR-075). The configuration
/// is written once; each frame keeps its own capture and expiry time. The envelope sequence is the
/// first frame's sequence and frame `i` has sequence `first + i`.
public struct EncodedAudioBatchPayload: Equatable, Sendable {
    public static let maximumFrameCount = 8

    public let frames: [EncodedAudioFramePayload]

    public var configuration: SessionAudioCodecConfiguration { frames[0].configuration }

    public init(frames: [EncodedAudioFramePayload]) throws {
        guard (1...Self.maximumFrameCount).contains(frames.count) else {
            throw EncodedAudioFrameError.invalidBatchCount(frames.count)
        }
        guard frames.allSatisfy({ $0.configuration == frames[0].configuration }) else {
            throw EncodedAudioFrameError.batchConfigurationMismatch
        }
        self.frames = frames
    }

    public func encode() -> Data {
        let configuration = configuration
        var writer = BinaryWriter(capacity: 32 + frames.reduce(0) { $0 + 20 + $1.encodedBytes.count })
        writer.append(configuration.codec.rawValue)
        writer.append(configuration.sampleRate)
        writer.append(configuration.channelCount)
        writer.append(configuration.frameDurationMilliseconds)
        writer.append(configuration.bitRate)
        writer.append(UInt32(configuration.codecSpecificData.count))
        writer.append(configuration.codecSpecificData)
        writer.append(UInt8(frames.count))
        for frame in frames {
            writer.append(frame.capturedAtNanoseconds)
            writer.append(frame.expiresAtNanoseconds)
            writer.append(UInt32(frame.encodedBytes.count))
            writer.append(frame.encodedBytes)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> EncodedAudioBatchPayload {
        var reader = BinaryReader(data: data)
        let codecRaw = try reader.readUInt8()
        guard let codec = SessionAudioCodec(rawValue: codecRaw) else {
            throw EncodedAudioFrameError.unsupportedCodec(codecRaw)
        }
        let sampleRate = try reader.readUInt32()
        let channelCount = try reader.readUInt8()
        let frameDuration = try reader.readUInt16()
        let bitRate = try reader.readUInt32()
        let codecSpecificData = try reader.readData(count: Int(try reader.readUInt32()))
        let configuration = try SessionAudioCodecConfiguration(
            codec: codec,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameDurationMilliseconds: frameDuration,
            bitRate: bitRate,
            codecSpecificData: codecSpecificData
        )
        let count = Int(try reader.readUInt8())
        guard (1...maximumFrameCount).contains(count) else { throw EncodedAudioFrameError.invalidBatchCount(count) }
        var frames: [EncodedAudioFramePayload] = []
        for _ in 0..<count {
            let capturedAt = try reader.readUInt64()
            let expiresAt = try reader.readUInt64()
            let length = Int(try reader.readUInt32())
            guard length <= reader.remaining else {
                throw SessionProtocolError.invalidPayloadLength(expected: length, actual: reader.remaining)
            }
            frames.append(try EncodedAudioFramePayload(
                configuration: configuration,
                capturedAtNanoseconds: capturedAt,
                expiresAtNanoseconds: expiresAt,
                encodedBytes: reader.readData(count: length)
            ))
        }
        guard reader.remaining == 0 else {
            throw SessionProtocolError.invalidPayloadLength(expected: 0, actual: reader.remaining)
        }
        return try EncodedAudioBatchPayload(frames: frames)
    }
}

public struct SequencedEncodedAudioBatch: Equatable, Sendable {
    public let firstSequence: UInt64
    public let payload: EncodedAudioBatchPayload

    public init(firstSequence: UInt64, payload: EncodedAudioBatchPayload) {
        self.firstSequence = firstSequence
        self.payload = payload
    }

    /// The frames in playout order with their individual sequences.
    public var sequencedFrames: [SequencedEncodedAudioFrame] {
        payload.frames.enumerated().map { index, frame in
            SequencedEncodedAudioFrame(sequence: firstSequence &+ UInt64(index), payload: frame)
        }
    }
}

/// Groups consecutive sender frames into batches. A batch closes when it is full, when a frame is not
/// the next sequence or changes configuration, or when the first pending frame has waited
/// `maximumWaitNanoseconds` (the caller schedules `flushIfDue` at `flushDeadlineNanoseconds`).
public struct AudioFrameBatcher: Sendable {
    public let maximumFrameCount: Int
    public let maximumWaitNanoseconds: UInt64

    private var pending: [EncodedAudioFramePayload] = []
    private var firstSequence: UInt64 = 0
    private var firstAppendedAtNanoseconds: UInt64 = 0

    public init(maximumFrameCount: Int, maximumWaitNanoseconds: UInt64) throws {
        guard (1...EncodedAudioBatchPayload.maximumFrameCount).contains(maximumFrameCount) else {
            throw EncodedAudioFrameError.invalidBatchCount(maximumFrameCount)
        }
        self.maximumFrameCount = maximumFrameCount
        self.maximumWaitNanoseconds = maximumWaitNanoseconds
    }

    public var pendingFrameCount: Int { pending.count }

    public var flushDeadlineNanoseconds: UInt64? {
        guard !pending.isEmpty else { return nil }
        let (deadline, overflow) = firstAppendedAtNanoseconds.addingReportingOverflow(maximumWaitNanoseconds)
        return overflow ? .max : deadline
    }

    public mutating func append(
        _ frame: SequencedEncodedAudioFrame,
        nowNanoseconds: UInt64
    ) throws -> [SequencedEncodedAudioBatch] {
        var batches: [SequencedEncodedAudioBatch] = []
        if !pending.isEmpty {
            let (next, overflow) = firstSequence.addingReportingOverflow(UInt64(pending.count))
            if overflow || frame.sequence != next || frame.payload.configuration != pending[0].configuration,
               let batch = try flushAll() {
                batches.append(batch)
            }
        }
        if pending.isEmpty {
            firstSequence = frame.sequence
            firstAppendedAtNanoseconds = nowNanoseconds
        }
        pending.append(frame.payload)
        if pending.count == maximumFrameCount, let batch = try flushAll() { batches.append(batch) }
        return batches
    }

    public mutating func flushIfDue(nowNanoseconds: UInt64) throws -> SequencedEncodedAudioBatch? {
        guard let deadline = flushDeadlineNanoseconds, nowNanoseconds >= deadline else { return nil }
        return try flushAll()
    }

    public mutating func flushAll() throws -> SequencedEncodedAudioBatch? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return SequencedEncodedAudioBatch(firstSequence: firstSequence, payload: try EncodedAudioBatchPayload(frames: pending))
    }

    /// Drops pending frames, for capture discontinuities and stop.
    public mutating func discard() {
        pending.removeAll(keepingCapacity: true)
    }
}
