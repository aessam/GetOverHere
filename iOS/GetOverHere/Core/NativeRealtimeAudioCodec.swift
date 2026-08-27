import AudioToolbox
import AVFAudio
import Foundation
import TourSessionCore

nonisolated enum NativeRealtimeAudioCodecError: Error, Equatable, CustomStringConvertible {
    case unsupportedCodec(SessionAudioCodec)
    case converterUnavailable(SessionAudioCodec)
    case invalidPCMByteCount(expected: Int, actual: Int)
    case inputBufferUnavailable
    case conversionFailed(status: Int, detail: String)
    case emptyEncodedPacket
    case emptyDecodedPacket

    var description: String {
        switch self {
        case let .unsupportedCodec(codec): "native codec is unavailable: \(codec)"
        case let .converterUnavailable(codec): "native converter is unavailable: \(codec)"
        case let .invalidPCMByteCount(expected, actual):
            "PCM frame has \(actual) bytes; expected \(expected)"
        case .inputBufferUnavailable: "native audio input buffer is unavailable"
        case let .conversionFailed(status, detail): "native audio conversion failed (\(status)): \(detail)"
        case .emptyEncodedPacket: "native encoder returned an empty packet"
        case .emptyDecodedPacket: "native decoder returned an empty PCM frame"
        }
    }
}

nonisolated struct NativeEncodedAudioPacket: Equatable, Sendable {
    let configuration: SessionAudioCodecConfiguration
    let bytes: Data
}

nonisolated protocol RealtimeAudioEncoderInterface: AnyObject {
    var codec: SessionAudioCodec { get }
    var inputPCMByteCount: Int { get }
    func encode(pcm16LittleEndian: Data) throws -> NativeEncodedAudioPacket?
}

nonisolated protocol RealtimeAudioDecoderInterface: AnyObject {
    var configuration: SessionAudioCodecConfiguration { get }
    func decode(packet: Data) throws -> Data?
}

nonisolated protocol RealtimeAudioCodecProviderInterface: Sendable {
    func sessionCapabilities() throws -> SessionCapabilities
    func makeEncoder(codec: SessionAudioCodec) throws -> any RealtimeAudioEncoderInterface
    func makeDecoder(
        configuration: SessionAudioCodecConfiguration
    ) throws -> any RealtimeAudioDecoderInterface
}

nonisolated struct NativeRealtimeAudioCodecProvider: RealtimeAudioCodecProviderInterface {
    func sessionCapabilities() throws -> SessionCapabilities {
        try NativeRealtimeAudioCodecFactory.sessionCapabilities()
    }

    func makeEncoder(codec: SessionAudioCodec) throws -> any RealtimeAudioEncoderInterface {
        try NativeRealtimeAudioCodecFactory.makeEncoder(codec: codec)
    }

    func makeDecoder(
        configuration: SessionAudioCodecConfiguration
    ) throws -> any RealtimeAudioDecoderInterface {
        try NativeRealtimeAudioCodecFactory.makeDecoder(configuration: configuration)
    }
}

nonisolated enum NativeRealtimeAudioCodecFactory {
    static func makeEncoder(codec: SessionAudioCodec) throws -> any RealtimeAudioEncoderInterface {
        try AppleNativeRealtimeAudioEncoder(codec: codec)
    }

    static func makeDecoder(
        configuration: SessionAudioCodecConfiguration
    ) throws -> any RealtimeAudioDecoderInterface {
        try AppleNativeRealtimeAudioDecoder(configuration: configuration)
    }

    static func sessionCapabilities() throws -> SessionCapabilities {
        let native = try NativeAudioCodecCapabilities.current()
        var result: SessionCapabilities = []
        if native.opusEncoder { result.insert(.opusEncoder) }
        if native.opusDecoder { result.insert(.opusDecoder) }
        if native.aacLCEncoder { result.insert(.aacLCEncoder) }
        if native.aacLCDecoder { result.insert(.aacLCDecoder) }
        return result
    }
}

nonisolated private final class AppleNativeRealtimeAudioEncoder: RealtimeAudioEncoderInterface {
    let codec: SessionAudioCodec
    let inputPCMByteCount: Int

    private let baseConfiguration: SessionAudioCodecConfiguration
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let frameCount: AVAudioFrameCount

    init(codec: SessionAudioCodec) throws {
        self.codec = codec
        let parameters = try Self.parameters(for: codec)
        baseConfiguration = try SessionAudioCodecConfiguration(
            codec: codec,
            sampleRate: parameters.sampleRate,
            channelCount: parameters.channelCount,
            frameDurationMilliseconds: parameters.frameDurationMilliseconds,
            bitRate: parameters.bitRate
        )
        frameCount = parameters.frameCount
        inputPCMByteCount = Int(frameCount) * Int(parameters.channelCount) * MemoryLayout<Int16>.size
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(parameters.sampleRate),
            channels: AVAudioChannelCount(parameters.channelCount),
            interleaved: true
        ) else {
            throw NativeRealtimeAudioCodecError.inputBufferUnavailable
        }
        self.inputFormat = inputFormat
        outputFormat = try Self.compressedFormat(configuration: baseConfiguration)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NativeRealtimeAudioCodecError.converterUnavailable(codec)
        }
        converter.bitRate = Int(parameters.bitRate)
        self.converter = converter
    }

    func encode(pcm16LittleEndian: Data) throws -> NativeEncodedAudioPacket? {
        guard pcm16LittleEndian.count == inputPCMByteCount else {
            throw NativeRealtimeAudioCodecError.invalidPCMByteCount(
                expected: inputPCMByteCount,
                actual: pcm16LittleEndian.count
            )
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw NativeRealtimeAudioCodecError.inputBufferUnavailable
        }
        input.frameLength = frameCount
        let inputAudioBuffer = input.mutableAudioBufferList.pointee.mBuffers
        guard let destination = inputAudioBuffer.mData else {
            throw NativeRealtimeAudioCodecError.inputBufferUnavailable
        }
        pcm16LittleEndian.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self),
            count: pcm16LittleEndian.count
        )
        input.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(pcm16LittleEndian.count)

        let maximumPacketSize = max(converter.maximumOutputPacketSize, 4_096)
        let output = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: maximumPacketSize
        )
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            throw NativeRealtimeAudioCodecError.conversionFailed(
                status: status.rawValue,
                detail: conversionError?.localizedDescription ?? "unknown error"
            )
        }
        guard output.byteLength > 0 else {
            if status == .inputRanDry { return nil }
            throw NativeRealtimeAudioCodecError.emptyEncodedPacket
        }
        let bytes = Data(bytes: output.data, count: Int(output.byteLength))
        let configuration = try SessionAudioCodecConfiguration(
            codec: baseConfiguration.codec,
            sampleRate: baseConfiguration.sampleRate,
            channelCount: baseConfiguration.channelCount,
            frameDurationMilliseconds: baseConfiguration.frameDurationMilliseconds,
            bitRate: baseConfiguration.bitRate,
            codecSpecificData: converter.magicCookie ?? outputFormat.magicCookie ?? Data()
        )
        return NativeEncodedAudioPacket(configuration: configuration, bytes: bytes)
    }

    fileprivate static func compressedFormat(
        configuration: SessionAudioCodecConfiguration
    ) throws -> AVAudioFormat {
        let formatID: AudioFormatID
        switch configuration.codec {
        case .opus: formatID = kAudioFormatOpus
        case .aacLC: formatID = kAudioFormatMPEG4AAC
        }
        let settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: Double(configuration.sampleRate),
            AVNumberOfChannelsKey: Int(configuration.channelCount),
            AVEncoderBitRateKey: Int(configuration.bitRate),
        ]
        guard let format = AVAudioFormat(settings: settings) else {
            throw NativeRealtimeAudioCodecError.unsupportedCodec(configuration.codec)
        }
        if !configuration.codecSpecificData.isEmpty {
            format.magicCookie = configuration.codecSpecificData
        }
        return format
    }

    private static func parameters(
        for codec: SessionAudioCodec
    ) throws -> (
        sampleRate: UInt32,
        channelCount: UInt8,
        frameDurationMilliseconds: UInt16,
        bitRate: UInt32,
        frameCount: AVAudioFrameCount
    ) {
        switch codec {
        case .opus:
            (16_000, 1, 20, 20_000, 320)
        case .aacLC:
            (16_000, 1, 64, 16_000, 1_024)
        }
    }
}

nonisolated private final class AppleNativeRealtimeAudioDecoder: RealtimeAudioDecoderInterface {
    let configuration: SessionAudioCodecConfiguration

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let outputFrameCapacity: AVAudioFrameCount

    init(configuration: SessionAudioCodecConfiguration) throws {
        self.configuration = configuration
        inputFormat = try AppleNativeRealtimeAudioEncoder.compressedFormat(configuration: configuration)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.sampleRate),
            channels: AVAudioChannelCount(configuration.channelCount),
            interleaved: true
        ) else {
            throw NativeRealtimeAudioCodecError.inputBufferUnavailable
        }
        self.outputFormat = outputFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NativeRealtimeAudioCodecError.converterUnavailable(configuration.codec)
        }
        if !configuration.codecSpecificData.isEmpty {
            converter.magicCookie = configuration.codecSpecificData
        }
        self.converter = converter
        outputFrameCapacity = AVAudioFrameCount(
            (UInt64(configuration.sampleRate) * UInt64(configuration.frameDurationMilliseconds)) / 1_000
        ) * 2
    }

    func decode(packet: Data) throws -> Data? {
        guard !packet.isEmpty else { throw NativeRealtimeAudioCodecError.emptyEncodedPacket }
        let input = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        packet.copyBytes(
            to: input.data.assumingMemoryBound(to: UInt8.self),
            count: packet.count
        )
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        if let descriptions = input.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(packet.count)
            )
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw NativeRealtimeAudioCodecError.inputBufferUnavailable
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            throw NativeRealtimeAudioCodecError.conversionFailed(
                status: status.rawValue,
                detail: conversionError?.localizedDescription ?? "unknown error"
            )
        }
        guard output.frameLength > 0 else {
            if status == .inputRanDry { return nil }
            throw NativeRealtimeAudioCodecError.emptyDecodedPacket
        }
        let audioBuffer = output.mutableAudioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            throw NativeRealtimeAudioCodecError.emptyDecodedPacket
        }
        return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    }
}
