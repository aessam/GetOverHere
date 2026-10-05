import Testing
@testable import GetOverHere

@Suite("Listener output")
struct ListenerOutputTests {
    @Test("Private audio is the default anti-feedback route")
    func defaultRoute() {
        let output = ListenerOutput.privateAudio

        #expect(output.title == "Earpiece")
        #expect(output.toggled == .speaker)
        #expect(output.toggled.toggled == .privateAudio)
    }

    @Test("Audio engine defaults to the private route")
    @MainActor
    func engineDefaultRoute() {
        // FND-12: read the engine's own default, not a literal the test happens to agree with.
        let engine = AudioEngine()

        #expect(engine.listenerOutput == .privateAudio)
        #expect(engine.listenerOutput.toggled == .speaker)
    }
}
