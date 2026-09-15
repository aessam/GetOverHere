import AVFoundation
import Foundation
import Network
import Testing
import TourSessionCore
import UIKit
@testable import GetOverHere

@Suite(.serialized) @MainActor
struct GatewayLifecycleTests {
    @Test(arguments: [false, true]) func alternateAppleAdvertiserSurvivesEitherRemovalOrder(removeFirst: Bool) throws {
        let transport = ApplePeerRoomTransport()
        defer { transport.stop() }
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Gateway fixture",
            isAndroid: true, isLocked: false, admissionVersion: 2)
        let first = NWEndpoint.hostPort(host: "127.0.0.1", port: 12340)
        let second = NWEndpoint.hostPort(host: "127.0.0.1", port: 12341)
        var lost: [UUID] = []
        transport.onLost = { lost.append($0) }
        transport.updateRecord(record, at: first)
        transport.updateRecord(record, at: second)
        transport.removeRecord(removeFirst ? first : second)
        #expect(transport.endpoints[record.roomID] == (removeFirst ? second : first))
        #expect(lost.isEmpty)
        transport.removeRecord(removeFirst ? second : first)
        #expect(lost == [record.roomID])
    }

    @Test func selectedAppleConnectorOutlivesDiscoverySnapshot() async throws {
        let transport = ApplePeerRoomTransport()
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Gateway fixture",
            isAndroid: true, isLocked: false, admissionVersion: 2)
        transport.updateRecord(record, at: .hostPort(host: "127.0.0.1", port: 12340))
        let selected = try transport.connector(roomID: record.roomID)
        transport.stop()
        #expect(transport.endpoints.isEmpty)
        // Opening a fresh native connection no longer consults the cleared index.
        // This checks ownership, not successful radio delivery to the fixture port.
        let connection = try await selected(.control)
        connection.close()
    }

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
