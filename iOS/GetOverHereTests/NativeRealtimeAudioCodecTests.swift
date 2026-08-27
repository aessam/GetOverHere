import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Native realtime audio codec")
struct NativeRealtimeAudioCodecTests {
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
