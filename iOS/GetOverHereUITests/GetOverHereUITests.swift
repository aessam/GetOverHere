//
//  GetOverHereUITests.swift
//  GetOverHereUITests
//
//  Created by Ahmed Essam on 3/23/26.
//

import XCTest

final class GetOverHereUITests: XCTestCase {
    /// Observe the installed app without launching a second coordinator or changing permissions.
    @MainActor
    func testObserveExistingDebugControlSession() throws {
        guard ProcessInfo.processInfo.environment["GOH_OBSERVE_DEBUG_CONTROL"] == "1" else {
            throw XCTSkip("Opt-in only: requires an already running authenticated debug session")
        }
        let app = XCUIApplication()
        app.activate()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Actual iPhone debug control UI"
        attachment.lifetime = .keepAlways
        add(attachment)
        let expected = ProcessInfo.processInfo.environment["GOH_DEBUG_EXPECT_SCREEN"] ?? "debug"
        if expected == "debug" {
            XCTAssertTrue(app.staticTexts["debugControlState"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(app.staticTexts["debugControlState"].label, "listening")
        } else if expected == "pointer" {
            XCTAssertTrue(app.segmentedControls.buttons["Pointer"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.segmentedControls.buttons["Pointer"].isSelected, app.debugDescription)
        } else {
            XCTFail("Unknown expected screen")
        }
    }

    @MainActor
    func testBluetoothDiscoveryDefaultsOffWithoutPromptingAtLaunch() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .bluetooth)
        app.launch()
        XCTAssertTrue(app.buttons["findNearbyTours"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["bluetoothRoomDiscovery"].exists, "Radio controls belong in diagnostics")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let bluetoothAlert = springboard.alerts.containing(NSPredicate(format: "label CONTAINS[c] 'Bluetooth'"))
        XCTAssertFalse(bluetoothAlert.firstMatch.waitForExistence(timeout: 2))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Find Nearby Tours without launch permissions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("A live guide requires physical microphone capture; simulator rollback has its own UI test")
#else
        addUIInterruptionMonitor(withDescription: "Tour permissions") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launch()

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.tap()

        let channelName = app.textFields["e.g., Tour Group, Lecture Hall"]
        XCTAssertTrue(channelName.waitForExistence(timeout: 2))
        channelName.tap()
        channelName.typeText("Alhambra")
        app.buttons["Create"].tap()
        app.tap()

        let featurePicker = app.segmentedControls.firstMatch
        XCTAssertTrue(featurePicker.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(featurePicker.buttons["Slides"].exists, app.debugDescription)
        XCTAssertTrue(featurePicker.buttons["Map"].exists, app.debugDescription)
        XCTAssertTrue(featurePicker.buttons["Pointer"].exists, app.debugDescription)

        let lockToggle = app.switches["roomLockToggle"]
        XCTAssertTrue(lockToggle.exists)
        XCTAssertEqual(lockToggle.value as? String, "0")
        let roomCode = app.textFields["roomCodeField"]
        roomCode.tap()
        roomCode.typeText("1234")
        app.keyboards.buttons["Done"].tap()
        lockToggle.switches.firstMatch.tap()
        XCTAssertTrue(NSPredicate(format: "value == '1'").evaluate(with: lockToggle)
            || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: lockToggle)], timeout: 10) == .completed, app.debugDescription)
        let lockedScreenshot = XCTAttachment(screenshot: app.screenshot())
        lockedScreenshot.name = "Room locked with editable code"
        lockedScreenshot.lifetime = .keepAlways
        add(lockedScreenshot)
        roomCode.tap()
        roomCode.typeText("5")
        app.keyboards.buttons["Done"].tap()
        app.buttons["Save Code"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: lockToggle)], timeout: 10), .completed)
        lockToggle.switches.firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: lockToggle)], timeout: 10), .completed)

        featurePicker.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["No Offline Map"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Import Offline Map"].exists)

        featurePicker.buttons["Pointer"].tap()
        XCTAssertTrue(
            app.staticTexts["Only the selected bearing angle is shared. Device location and guest compass readings stay local."]
                .waitForExistence(timeout: 2)
        )
        app.buttons["End Tour"].tap()
#endif
    }

    @MainActor
    func testFailedStartupShowsReasonOnChannelList() throws {
#if targetEnvironment(simulator)
        // Exercise the real startup rollback: simulator microphone capture is unsupported.
        let app = XCUIApplication()
        app.launch()
        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        let channelName = app.textFields["e.g., Tour Group, Lecture Hall"]
        XCTAssertTrue(channelName.waitForExistence(timeout: 3))
        channelName.tap()
        channelName.typeText("Startup failure")
        app.buttons["Create"].tap()

        let error = app.staticTexts["tourStartupError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(error.label, "Microphone capture is unavailable in the iOS Simulator")
        XCTAssertFalse(app.segmentedControls.firstMatch.exists, "Failed startup must not show a live tour")
        XCTAssertTrue(addButton.exists, "The user must be able to retry")
#else
        throw XCTSkip("Uses the simulator's real unsupported-capture failure")
#endif
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
