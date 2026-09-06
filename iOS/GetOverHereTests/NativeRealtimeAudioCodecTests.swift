import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Native realtime audio codec")
struct NativeRealtimeAudioCodecTests {
    private final class FixtureBundle {}

    @Test("Production Android packets preserve duration, tone and level", arguments: SessionAudioCodec.allCases)
    func androidPackets(codec: SessionAudioCodec) throws {
        let path = ProcessInfo.processInfo.environment["GOH_ANDROID_CODEC_FIXTURE"]
        let url = try #require(path.map { URL(fileURLWithPath: $0) }
            ?? Bundle(for: FixtureBundle.self).url(forResource: "android-native-codec", withExtension: "hex"))
        let frames = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try EncodedAudioFramePayload.decode(Data(hex: String($0)))
        }.filter { $0.configuration.codec == codec }
        #expect(frames.count >= 32)
        let config = try #require(frames.first).configuration
        let decoder = try NativeRealtimeAudioCodecFactory.makeDecoder(configuration: config)
        var pcm = Data()
        for frame in frames {
            if let decoded = try decoder.decode(packet: frame.encodedBytes) { pcm.append(decoded) }
        }
        let frameSamples = Int(config.sampleRate) * Int(config.frameDurationMilliseconds) / 1_000
        let expected = frames.count * frameSamples
        #expect(abs(pcm.count / 2 - expected) <= 2 * frameSamples)
        let samples = stride(from: 0, to: pcm.count, by: 2).map {
            Double(Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8))
        }.dropFirst(2 * frameSamples)
        try #require(!samples.isEmpty)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        #expect(rms > 1_000)
        let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = Double(crossings) * Double(config.sampleRate) / Double(samples.count)
        #expect(abs(frequency - 440) < 10)
    }

    @Test("Opus and AAC-LC encode and decode native PCM16 frames", arguments: SessionAudioCodec.allCases)
    func nativeRoundtrip(codec: SessionAudioCodec) throws {
        let encoder = try NativeRealtimeAudioCodecFactory.makeEncoder(codec: codec)
        var decoder: (any RealtimeAudioDecoderInterface)?
        var encodedByteCount = 0
        var decodedByteCount = 0
        var producedPacketCount = 0

        for frameIndex in 0 ..< 24 {
            let pcm = sineFrame(byteCount: encoder.inputPCMByteCount, frameIndex: frameIndex)
            guard let packet = try encoder.encode(pcm16LittleEndian: pcm) else { continue }
            producedPacketCount += 1
            encodedByteCount += packet.bytes.count
            if decoder == nil {
                decoder = try NativeRealtimeAudioCodecFactory.makeDecoder(configuration: packet.configuration)
            }
            if let decoded = try decoder?.decode(packet: packet.bytes) {
                decodedByteCount += decoded.count
            }
        }

        #expect(producedPacketCount > 0)
        #expect(encodedByteCount > 0)
        #expect(decodedByteCount > 0)
        #expect(encodedByteCount < 24 * encoder.inputPCMByteCount)
    }

    @Test("Native capabilities map to session negotiation bits")
    func capabilities() throws {
        let capabilities = try NativeRealtimeAudioCodecFactory.sessionCapabilities()
        #expect(capabilities.contains(.opusEncoder))
        #expect(capabilities.contains(.opusDecoder))
        #expect(capabilities.contains(.aacLCEncoder))
        #expect(capabilities.contains(.aacLCDecoder))
    }

    private func sineFrame(byteCount: Int, frameIndex: Int) -> Data {
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for index in 0 ..< sampleCount {
            let phase = Double(frameIndex * sampleCount + index) * 440 * 2 * .pi / 16_000
            samples.append(Int16(sin(phase) * Double(Int16.max) * 0.25))
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
