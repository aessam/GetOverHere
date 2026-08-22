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
}
