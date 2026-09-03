import Testing
@testable import GetOverHere

@Suite("Guest connection status")
struct GuestConnectionStatusTests {
    @Test("Failed state renders the product version-mismatch message")
    @MainActor
    func failedStateRendersVersionMismatch() {
        let message = ChannelService.versionMismatchMessage(remoteMajor: 2, localMajor: 3)
        let text = ChannelService.ConnectionState.failed.guestStatusText(error: message)

        #expect(text == message)
        #expect(text.contains("remote 2"))
        #expect(text.contains("local 3"))
        #expect(text.contains("Update the older app"))
    }

    @Test("Failed state without a reason renders the generic label")
    @MainActor
    func genericFailure() {
        #expect(ChannelService.ConnectionState.failed.guestStatusText(error: nil) == "CONNECTION FAILED")
    }

    @Test("Reconnecting renders the attempt counter and ignores the reason")
    @MainActor
    func reconnecting() {
        let text = ChannelService.ConnectionState.reconnecting(attempt: 2)
            .guestStatusText(error: "Guide connection closed")
        #expect(text == "RECONNECTING 2/5")
    }

    @Test("Non-failed states ignore a stale error")
    @MainActor
    func connectedIgnoresStaleError() {
        #expect(ChannelService.ConnectionState.connected.guestStatusText(error: "stale") == "LISTENING")
        #expect(ChannelService.ConnectionState.connecting.guestStatusText(error: "stale") == "CONNECTING")
        #expect(ChannelService.ConnectionState.idle.guestStatusText(error: "stale") == "IDLE")
    }
}
