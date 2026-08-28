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
}
