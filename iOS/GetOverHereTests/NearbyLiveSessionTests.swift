import Foundation
import os
import Testing
import TourSessionCore
import UIKit
@testable import GetOverHere

/// Opt-in real microphone/playback test through the production session service.
/// The guest deliberately excludes LAN from its selected discovery record, then
/// asserts the native route. This does not change either phone's Wi-Fi settings.
@MainActor
struct NearbyLiveSessionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOH_NEARBY_LIVE_ROOM_NAME"] != nil))
    func productionSessionDeliversLiveAudioAndReadinessOverBluetooth() async throws {
        #if targetEnvironment(simulator)
        throw LiveFailure.physicalDeviceRequired
        #else
        let environment = ProcessInfo.processInfo.environment
        let name = try #require(environment["GOH_NEARBY_LIVE_ROOM_NAME"])
        let role = try #require(environment["GOH_NEARBY_ROLE"])
        try #require(role == "guide" || role == "guest")
        try #require(UIApplication.shared.applicationState == .active,
                     "Foreground live test requires the iPhone app to be visible and unlocked")
        let app = AppCoordinator(displayName: "iOS physical live test")
        let service = app.channelService
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        app.start()
        service.bluetoothDiscoveryEnabled = true
        // Test one explicit native route; Aware qualification is a separate gate.
        service.awareDiscoveryEnabled = false
        defer {
            app.stop()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
        }

        if role == "guide" {
            service.createChannel(name: name)
            try await waitUntil("guide microphone startup", seconds: 15, service: service) {
                service.listenState == .broadcasting && service.audioRuntimeState == .running
            }
            // Production Create enables both nearby radios after asynchronous microphone startup.
            // Apply the fixture's explicit BLE selection after that action has finished.
            service.awareDiscoveryEnabled = false
            try #require(service.bluetoothDiscoveryEnabled && !service.awareDiscoveryEnabled)
            #expect(!service.isRoomLocked)
            try await waitUntil("guest audio-ready report", seconds: 90, service: service) {
                service.tourControlService.audioReadyGuestCount == 1
            }
            service.setVisualFocus(.pointer)
            // Let the guest verify pointer delivery and sustained renderer acceptance.
            try await Task.sleep(for: .seconds(10))
            #expect(service.audioRuntimeState == .running)
        } else {
            try await waitUntil("joinable Bluetooth room", seconds: 90, service: service) {
                service.channels.contains { channel in
                    var selected = channel
                    selected.audioHostIP = nil
                    return selected.name == name && service.canJoin(selected)
                }
            }
            var selected = try #require(service.channels.first { $0.name == name })
            selected.audioHostIP = nil
            service.joinChannel(selected, tourCode: "")
            try await waitUntil("authenticated live playback", seconds: 45, service: service) {
                service.connectionState == .connected && service.audioRuntimeState == .running
            }
            #expect(service.guestRoute?.transport == .bluetooth)
            #expect(service.guestRoute?.roomID == UUID(uuidString: selected.id))
            try await waitUntil("authoritative pointer state", seconds: 15, service: service) {
                service.tourControlService.visualFocusSnapshot?.mode == .pointer
            }
            var acceptedBytes = app.audioEngine.acceptedPlaybackByteCount
            let initialAcceptedBytes = acceptedBytes
            let cadenceStarted = ContinuousClock.now
            for _ in 0..<5 {
                try await Task.sleep(for: .seconds(1))
                try #require(service.audioRuntimeState == .running, "Live renderer stopped")
                try #require(service.connectionState == .connected, "Live control disconnected")
                try #require(service.guestRoute?.transport == .bluetooth, "Route changed away from Bluetooth")
                let updatedBytes = app.audioEngine.acceptedPlaybackByteCount
                try #require(updatedBytes > acceptedBytes, "No new PCM accepted by renderer for one second")
                acceptedBytes = updatedBytes
            }
            let deliveredBytes = acceptedBytes - initialAcceptedBytes
            let elapsed = cadenceStarted.duration(to: .now)
            Logger.transport.info("Live BLE cadence: acceptedPCMBytes=\(deliveredBytes), elapsed=\(String(describing: elapsed), privacy: .public), minimumPCMBytes=128000")
            // 16 kHz mono PCM16 is 32,000 bytes/s. This smoke gate requires 80% of
            // five nominal seconds; it is not an acoustic or latency acceptance test.
            try #require(deliveredBytes >= 128_000, "Live PCM cadence below the five-second smoke threshold")
        }
        #endif
    }

    private enum LiveFailure: Error {
        case physicalDeviceRequired
        case failed(stage: String, detail: String)
    }

    private func waitUntil(_ stage: String, seconds: Int, service: ChannelService,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            if service.connectionState == .failed || service.audioRuntimeState == .failed {
                throw LiveFailure.failed(stage: stage,
                    detail: service.audioRuntimeError ?? service.tourFeatureError ?? "Session failed")
            }
            guard ContinuousClock.now < deadline else {
                throw LiveFailure.failed(stage: stage,
                    detail: "Timed out; connection=\(service.connectionState), audio=\(service.audioRuntimeState), " +
                        "nearby=\(service.nearbyError ?? "none"), session=\(service.tourFeatureError ?? "none")")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
