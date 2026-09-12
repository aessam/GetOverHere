import AVFoundation
import Foundation
import Testing
import UIKit
@testable import GetOverHere

@Suite(.serialized) @MainActor
struct GatewayLifecycleTests {
    @Test func firstScanRequestsCameraPermissionBeforeCreatingScanner() {
        #expect(GatewayCameraAuthorization.action(for: .notDetermined) == .request)
        #expect(GatewayCameraAuthorization.action(for: .authorized) == .scan)
        #expect(GatewayCameraAuthorization.action(for: .denied) == .settings)
        #expect(GatewayCameraAuthorization.action(for: .restricted) == .settings)
    }

    @Test func debugAndCompanionKeepAwakeHaveIndependentLifetimes() {
        let original = UIApplication.shared.isIdleTimerDisabled
        let debug = UUID(), companion = UUID()
        defer { IdleTimerOwnership.release(debug); IdleTimerOwnership.release(companion) }
        IdleTimerOwnership.acquire(debug)
        IdleTimerOwnership.acquire(companion)
        IdleTimerOwnership.release(debug)
        #expect(UIApplication.shared.isIdleTimerDisabled)
        IdleTimerOwnership.release(companion)
        #expect(UIApplication.shared.isIdleTimerDisabled == original)
    }

    @Test func malformedAndOffLinkWiredEndpointsFailClosed() {
        for host in ["example.com", "127.0.0.1", "192.0.2.1", "", "::1"] {
            #expect(throws: (any Error).self) { try WiredInterfaceMonitor.peerHost(host, on: "interface-not-present") }
        }
    }

    @Test func localRecorderCannotStartWithoutRealActiveTour() {
        let recorder = GatewayScenarioRecorder()
        #expect(throws: (any Error).self) {
            try recorder.start(seconds: 1) { "{\"role\":\"none\",\"activeRoom\":\"\"}" }
        }
        #expect(recorder.state == "idle")
        #expect(recorder.evidenceURL == nil)
    }
}
