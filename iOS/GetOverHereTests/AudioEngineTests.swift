import AVFoundation
import Testing
@testable import GetOverHere

@Suite("Audio engine")
struct AudioEngineTests {
    @Test("Simulator capture fails explicitly instead of publishing an empty stream")
    @MainActor
    func simulatorCaptureFailsExplicitly() {
#if targetEnvironment(simulator)
        let engine = AudioEngine()
        do {
            _ = try engine.startCapture()
            Issue.record("Simulator capture unexpectedly started")
        } catch let error as AudioEngineError {
            guard case .captureUnavailable = error else {
                Issue.record("Unexpected audio error: \(error)")
                return
            }
            #expect(!engine.isCapturing)
        } catch {
            Issue.record("Unexpected error type")
        }
#endif
    }

    // FND-13: the observers themselves need audio hardware (simulator capture is unsupported by
    // design, CLAUDE.md), so the decisions they take are pure functions pinned here; headset
    // plug/unplug and an incoming call are P3 physical checklist items.

    @Test("Interruption notifications map to pause, resume, stop, or ignore")
    func interruptionActionMapping() {
        #expect(AudioEngine.interruptionAction(for: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ]) == .pause)
        #expect(AudioEngine.interruptionAction(for: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]) == .resume)
        #expect(AudioEngine.interruptionAction(for: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ]) == .stop)
        #expect(AudioEngine.interruptionAction(for: nil) == .ignore)
        #expect(AudioEngine.interruptionAction(for: [AVAudioSessionInterruptionTypeKey: "garbage"]) == .ignore)
        #expect(AudioEngine.interruptionAction(for: [AVAudioSessionInterruptionTypeKey: UInt(99)]) == .ignore)
    }

    @Test("Converter rebuild is required only when the input format changed")
    func converterRebuildDecision() throws {
        let mono48 = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let mono44 = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let stereo48 = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let int48 = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))

        #expect(!AudioEngine.needsConverterRebuild(current: mono48, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: mono44, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: stereo48, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: int48, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: mono48, converterInput: nil))
    }
}
