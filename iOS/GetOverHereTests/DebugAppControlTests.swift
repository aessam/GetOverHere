#if DEBUG
import AppDebugControl
import Foundation
import Testing
@testable import GetOverHere

@MainActor
struct DebugAppControlTests {
    @Test func statusReadsTheSameCoordinatorAndDoesNotExposeCredentials() throws {
        let app = AppCoordinator(displayName: "Debug test")
        let adapter = DebugAppControl(app: app)
        app.selectedTourFeature = .pointer
        app.showCreateChannel = true
        let text = try adapter.execute(DebugRequest(command: "status"))
        let value = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(value["screen"] as? String == "create")
        #expect(value["feature"] as? String == "pointer")
        #expect(value["acceptedPlaybackBytes"] as? Int == 0)
        #expect(value["code"] == nil && value["key"] == nil && value["credential"] == nil)
    }

    @Test func unknownCommandsAndUnexpectedArgumentsFailClosed() throws {
        let app = AppCoordinator(displayName: "Debug test")
        let adapter = DebugAppControl(app: app)
        #expect(throws: (any Error).self) { try adapter.execute(DebugRequest(command: "eval", arguments: ["code": "anything"])) }
        #expect(throws: (any Error).self) { try adapter.execute(DebugRequest(command: "status", arguments: ["key": "anything"])) }
        #expect(app.channelService.activeChannelID == nil)
    }

    @Test func ordinaryLaunchDoesNotStartAListener() {
        let app = AppCoordinator(displayName: "Debug test")
        let adapter = DebugAppControl(app: app)
        adapter.startIfRequested(environment: [:])
        #expect(adapter.state == "disabled" && adapter.port == nil)
        adapter.startIfRequested(environment: ["GOH_DEBUG_CONTROL": "1"])
        #expect(adapter.state == "configuration-failed" && adapter.port == nil)
    }
}
#endif
