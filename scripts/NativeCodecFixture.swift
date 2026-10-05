import Foundation
import TourSessionCore

/// Uses production Apple codec code with a generated tone, never recorded speech.
@main enum NativeCodecFixture {
    static func main() throws {
        for codec in SessionAudioCodec.allCases {
            let encoder = try NativeRealtimeAudioCodecFactory.makeEncoder(codec: codec)
            for frame in 0..<32 {
                let count = encoder.inputPCMByteCount / 2
                let samples = (0..<count).map { index in
                    Int16(sin(Double(frame * count + index) * 440 * 2 * .pi / 16_000) * 8_000)
                }
                let pcm = samples.withUnsafeBytes { Data($0) }
                guard let packet = try encoder.encode(pcm16LittleEndian: pcm) else { continue }
                let payload = try EncodedAudioFramePayload(configuration: packet.configuration,
                    capturedAtNanoseconds: 1, expiresAtNanoseconds: 2, encodedBytes: packet.bytes)
                print(payload.encode().lowercaseHex)
            }
        }
    }
}
