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
        }
    }
}

public struct SessionAudioCodecConfiguration: Equatable, Sendable {
    public let codec: SessionAudioCodec
    public let sampleRate: UInt32
    public let channelCount: UInt8
    public let frameDurationMilliseconds: UInt16
    public let bitRate: UInt32

    public init(
        codec: SessionAudioCodec,
        sampleRate: UInt32,
        channelCount: UInt8,
        frameDurationMilliseconds: UInt16,
        bitRate: UInt32
    ) throws {
        guard sampleRate > 0 else { throw EncodedAudioFrameError.invalidSampleRate(sampleRate) }
        guard channelCount > 0 else { throw EncodedAudioFrameError.invalidChannelCount(channelCount) }
        guard frameDurationMilliseconds > 0 else {
            throw EncodedAudioFrameError.invalidFrameDuration(frameDurationMilliseconds)
        }
        guard bitRate > 0 else { throw EncodedAudioFrameError.invalidBitRate(bitRate) }
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.bitRate = bitRate
    }
}

public struct EncodedAudioFramePayload: Equatable, Sendable {
    public static let fixedHeaderSize = 32

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
        let configuration = try SessionAudioCodecConfiguration(
            codec: codec,
            sampleRate: reader.readUInt32(),
            channelCount: reader.readUInt8(),
            frameDurationMilliseconds: reader.readUInt16(),
            bitRate: reader.readUInt32()
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
        if sender.contains(.opusEncoder), receiver.contains(.opusDecoder) {
            return .opus
        }
        if sender.contains(.aacLCEncoder), receiver.contains(.aacLCDecoder) {
            return .aacLC
        }
        throw EncodedAudioFrameError.noCommonCodec
    }
}
