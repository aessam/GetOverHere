import Testing
@testable import GetOverHere

@Suite("Native audio codec capabilities")
struct NativeAudioCodecCapabilitiesTests {
    @Test("Installed native encoders and decoders are reported")
    func reportsInstalledCodecs() throws {
        let capabilities = try NativeAudioCodecCapabilities.current()

        print(
            "GOH_CODEC_CAPABILITY " +
                "opusEncoder=\(capabilities.opusEncoder) " +
                "opusDecoder=\(capabilities.opusDecoder) " +
                "aacLCEncoder=\(capabilities.aacLCEncoder) " +
                "aacLCDecoder=\(capabilities.aacLCDecoder)"
        )

        #expect(capabilities.aacLCEncoder)
        #expect(capabilities.aacLCDecoder)
    }
}
