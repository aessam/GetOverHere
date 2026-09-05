import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// ChannelService lifecycle proofs (G4): FND-2 startup ordering and rollback, FND-6 discovery-driven
/// reconfiguration, FND-8 terminal paths and the asynchronous leave flush, FND-13 counts and
/// warnings, plus the G3 hand-off `audioLaneLossSchedulesReconnect` (DSCN-28).
///
/// The credential stretch runs off the main actor (ADR-042), so every step after
/// `createChannel`/`joinChannel` polls with a real wait before emitting fake lane events (RSK-4).
@Suite("ChannelService lifecycle", .serialized)
struct ChannelServiceLifecycleTests {
    private enum TestTimeout: Error {
        case expired(String)
    }

    @MainActor
    private final class Harness {
        let controlPlane = LifecycleControlPlane()
        let audioPlane = LifecycleAudioPlane()
        let control = LifecycleControlTransport()
        let asset = LifecycleAssetTransport()
        let engine = FakeAudioEngine()
        let coordinator: NetworkCoordinator
        let service: ChannelService
        private let root: URL

        init(reconnectBaseDelay: Duration = .milliseconds(1)) throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "GetOverHereLifecycle-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            coordinator = NetworkCoordinator(
                displayName: "Local",
                controlPlane: controlPlane,
                audioPlane: audioPlane
            )
            service = ChannelService(
                coordinator: coordinator,
                audioEngine: engine,
                tourControlService: TourControlService(transport: control),
                assetTransferService: TourAssetTransferService(
                    transport: asset,
                    cache: try FileTourAssetCache(rootDirectory: root.appending(path: "cache"))
                ),
                contentStore: try TourContentStore(rootDirectory: root.appending(path: "packs")),
                localGuidanceService: LocalGuidanceService(),
                reconnectBaseDelay: reconnectBaseDelay,
                roomAdmission: LifecycleRoomAdmission()
            )
        }

        func resetClearSessionBaselines() {
            control.clearSessionCalls = 0
            asset.clearSessionCalls = 0
            audioPlane.clearSessionCalls = 0
        }

        func close() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                fputs("Lifecycle harness cleanup failed (\(String(describing: type(of: error))))\n", stderr)
            }
        }
    }

    // MARK: - FND-2

    @Test("room settings never reconfigure existing media lanes")
    @MainActor
    func roomSettingsPreserveExistingConnections() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        h.service.createChannel(name: "Open room")
        try await waitUntil("guide startup") { h.service.connectionState == .connected }
        #expect(!h.service.isRoomLocked)
        #expect(h.service.tourCode == "")
        let controlConfigurations = h.control.configureCalls
        let audioConfigurations = h.audioPlane.configureCalls
        let assetConfigurations = h.asset.configureCalls
        for (locked, code) in [(true, "1234"), (true, "Edited!"), (false, "Edited!")] {
            h.service.updateRoomAccess(locked: locked, code: code)
            try await waitUntil("room update") { !h.service.isUpdatingRoomAccess }
            #expect(h.service.roomAccessError == nil)
            #expect(h.service.isRoomLocked == locked)
            #expect(h.service.tourCode == code)
            #expect(h.service.connectionState == .connected)
            #expect(h.control.configureCalls == controlConfigurations)
            #expect(h.audioPlane.configureCalls == audioConfigurations)
            #expect(h.asset.configureCalls == assetConfigurations)
        }
    }

    @Test("createChannel publishes only after every lane and capture started")
    @MainActor
    func createChannelPublishesOnlyAfterCaptureStarts() async throws {
        let h = try Harness()
        defer { h.close() }
        h.engine.startCaptureError = AudioEngineError.captureUnavailable
        var broadcastingCallsAtCaptureStart = -1
        h.engine.onStartCapture = { [audioPlane = h.audioPlane] in
            broadcastingCallsAtCaptureStart = audioPlane.startBroadcastingCalls
        }

        h.service.createChannel(name: "Tour")
        try await waitUntil("failed guide startup") { h.service.connectionState == .failed }

        #expect(h.service.listenState == .idle)
        #expect(h.service.channels.isEmpty)
        #expect(h.service.activeChannelID == nil)
        #expect(h.service.tourFeatureError == AudioEngineError.captureUnavailable.localizedDescription)
        #expect(h.controlPlane.announcedChannelIDs.isEmpty, "Bonjour must not advertise a tour that cannot capture")
        #expect(h.controlPlane.endedChannelIDs.count == 1)
        #expect(h.control.clearSessionCalls == 1)
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)
        #expect(broadcastingCallsAtCaptureStart == 1, "audio lane starts before capture")
        #expect(h.engine.startCaptureCalls == 1)
    }

    @Test("createChannel rolls back when the control lane fails to bind")
    @MainActor
    func createChannelRollsBackWhenControlLaneFailsToBind() async throws {
        let h = try Harness()
        defer { h.close() }
        h.control.startGuideError = LifecycleLaneError.bind("Session: bind/listen failed: Address already in use")

        h.service.createChannel(name: "Tour")
        try await waitUntil("failed guide startup") { h.service.connectionState == .failed }

        #expect(h.service.listenState == .idle)
        #expect(h.service.channels.isEmpty)
        #expect(h.service.tourFeatureError?.contains("bind/listen failed") == true)
        #expect(h.controlPlane.announcedChannelIDs.isEmpty)
        #expect(h.controlPlane.endedChannelIDs.count == 1)
        #expect(h.control.clearSessionCalls == 1)
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 0, "no audio plane was selected before the bind failure")
        #expect(h.audioPlane.startBroadcastingCalls == 0)
        #expect(h.engine.startCaptureCalls == 0)
    }

    // MARK: - FND-6

    @Test("Guide address change reconfigures the lanes without clearing the session")
    @MainActor
    func guideAddressChangeReconfiguresWithoutClearingSession() async throws {
        let h = try Harness()
        defer { h.close() }
        let channel = try await discoverAndJoin(h, hostIP: "10.0.0.1")
        try await connectGuest(h)
        h.resetClearSessionBaselines()

        h.controlPlane.emit(.channelAnnounce(announce: announce(channel, audioHostIP: "10.0.0.2")))
        try await waitUntil("guest lanes restarted") { h.control.startGuestCalls == 2 }

        #expect(h.control.clearSessionCalls == 0)
        #expect(h.asset.clearSessionCalls == 0)
        #expect(h.audioPlane.clearSessionCalls == 0)
        #expect(h.control.startGuestHostIPs.last == "10.0.0.2")
        #expect(h.service.connectionState == .connecting)
    }

    // MARK: - FND-8

    @Test("Bluetooth-only discovery cannot restart an authenticated LAN session")
    @MainActor
    func bluetoothObservationPreservesActiveSession() async throws {
        let h = try Harness()
        defer { h.close() }
        let channel = try await discoverAndJoin(h)
        try await connectGuest(h)
        h.resetClearSessionBaselines()
        h.controlPlane.emit(.channelAnnounce(announce: BLECommand.ChannelAnnounce(
            channelID: channel.id, channelName: "Bluetooth room", createdBy: channel.createdBy,
            audioQuality: .standard, wifiSSID: nil, audioHostIP: nil)))
        try await waitUntil("Bluetooth metadata applied") { h.service.channels.first?.name == "Bluetooth room" }
        #expect(h.control.startGuestCalls == 1)
        #expect(h.control.clearSessionCalls == 0)
        #expect(h.service.connectionState == .connected)
    }

    @Test("End Tour flushes the leave off the main actor and clears lanes after delivery")
    @MainActor
    func endTourFlushesLeaveOffMainAndClearsAfterDelivery() async throws {
        let h = try Harness()
        defer { h.close() }
        let channel = try await createGuide(h)
        h.control.holdLeave = true

        h.service.leaveChannel()

        #expect(h.service.listenState == .idle)
        #expect(h.service.activeChannelID == nil)
        #expect(h.controlPlane.endedChannelIDs.last == channel.id)
        try await waitUntil("leave flush started") { h.control.leaveFlushCount == 1 }
        #expect(!h.control.blockingLeaveUsed, "End Tour must not use the blocking leave path")
        #expect(h.control.clearSessionCalls == 0, "lanes stay until the leave is delivered")
        #expect(h.asset.clearSessionCalls == 0)
        #expect(h.audioPlane.clearSessionCalls == 0)

        h.control.resumeLeave()

        try await waitUntil("lanes cleared after delivery") { h.control.clearSessionCalls == 1 }
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)
    }

    /// A second End Tour tap or a termination with no active channel inside the flush window must
    /// not disown the pending teardown: the lanes still hold the ended tour's credential (ADR-048).
    @Test("End Tour teardown survives a no-op leave inside the flush window")
    @MainActor
    func endTourTeardownSurvivesANoOpLeave() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await createGuide(h)
        h.control.holdLeave = true

        h.service.leaveChannel()
        try await waitUntil("leave flush started") { h.control.leaveFlushCount == 1 }
        #expect(h.service.activeChannelID == nil)

        h.service.leaveChannel()
        h.service.terminate()

        #expect(h.control.leaveFlushCount == 1, "no-op leaves must not flush again")
        #expect(h.control.clearSessionCalls == 0, "lanes stay until the leave is delivered")

        h.control.resumeLeave()

        try await waitUntil("lanes cleared after delivery despite the no-op leave") {
            h.control.clearSessionCalls == 1
        }
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)
    }

    /// A Create started inside the flush window whose credential stretch outlives the flush must
    /// survive the deferred teardown: the teardown belongs to the leave that already invalidated
    /// older stretches and must not discard the user's newest action (ADR-048).
    @Test("End Tour teardown does not discard a Create started inside the flush window")
    @MainActor
    func endTourTeardownDoesNotDiscardAFollowingCreate() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await createGuide(h)
        h.control.holdLeave = true

        h.service.leaveChannel()
        try await waitUntil("leave flush started") { h.control.leaveFlushCount == 1 }

        h.service.createChannel(name: "Tour 2")
        h.control.resumeLeave()

        try await waitUntil("second tour broadcasting after the deferred teardown") {
            h.service.listenState == .broadcasting
        }
        #expect(h.service.activeChannel?.name == "Tour 2")
        #expect(h.control.clearSessionCalls == 1, "the ended tour's lanes were still cleared")
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)
    }

    @Test("Version mismatch erases the transport credentials")
    @MainActor
    func versionMismatchErasesTransportCredentials() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await discoverAndJoin(h)
        try await connectGuest(h)
        h.resetClearSessionBaselines()

        h.control.emit(.versionMismatch(remoteMajor: 3, localMajor: 4))
        try await waitUntil("failed") { h.service.connectionState == .failed }

        #expect(h.service.tourFeatureError?.contains("version mismatch") == true)
        #expect(h.control.clearSessionCalls == 1)
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)

        h.control.emit(.disconnected)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.service.connectionState == .failed)
        #expect(h.control.startGuestCalls == 1)
    }

    @Test("Credential rejection is terminal and never retried")
    @MainActor
    func credentialRejectionIsTerminal() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await discoverAndJoin(h)
        h.resetClearSessionBaselines()

        h.control.emit(.credentialRejected("Session: the tour code was rejected by the guide"))
        try await waitUntil("failed") { h.service.connectionState == .failed }

        #expect(h.service.tourFeatureError?.contains("tour code") == true)
        #expect(h.control.clearSessionCalls == 1)
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)

        try await Task.sleep(for: .milliseconds(50))
        #expect(h.control.startGuestCalls == 1, "a rejected code is never retried")
        #expect(h.service.connectionState == .failed)
    }

    @Test("Reconnect exhaustion erases the transport credentials")
    @MainActor
    func reconnectExhaustionErasesTransportCredentials() async throws {
        let h = try Harness(reconnectBaseDelay: .milliseconds(1))
        defer { h.close() }
        _ = try await discoverAndJoin(h)
        try await connectGuest(h)
        h.resetClearSessionBaselines()
        h.control.onStartGuest = { [control = h.control] in
            control.emit(.failed("connect failed"))
        }

        h.control.emit(.disconnected)
        try await waitUntil("exhausted") { h.service.connectionState == .failed }

        #expect(h.service.tourFeatureError == "Could not reconnect to the guide")
        #expect(h.control.clearSessionCalls == 1)
        #expect(h.asset.clearSessionCalls == 1)
        #expect(h.audioPlane.clearSessionCalls == 1)
        #expect(h.control.startGuestCalls == 6)

        try await Task.sleep(for: .milliseconds(100))
        #expect(h.control.startGuestCalls == 6)
    }

    @Test("terminate() clears all lanes for a guide and for a guest")
    @MainActor
    func terminateClearsAllLanesForGuideAndGuest() async throws {
        let guide = try Harness()
        defer { guide.close() }
        let channel = try await createGuide(guide)

        guide.service.terminate()

        #expect(guide.control.sent.contains { $0.kind == .leave })
        #expect(guide.control.blockingLeaveUsed, "termination uses the synchronous bounded flush")
        #expect(guide.control.clearSessionCalls == 1)
        #expect(guide.asset.clearSessionCalls == 1)
        #expect(guide.audioPlane.clearSessionCalls == 1)
        #expect(guide.service.listenState == .idle)
        #expect(guide.controlPlane.endedChannelIDs.last == channel.id)

        let guest = try Harness()
        defer { guest.close() }
        _ = try await discoverAndJoin(guest)
        try await connectGuest(guest)
        guest.resetClearSessionBaselines()

        guest.service.terminate()

        #expect(guest.control.clearSessionCalls == 1)
        #expect(guest.asset.clearSessionCalls == 1)
        #expect(guest.audioPlane.clearSessionCalls == 1)
        #expect(guest.service.activeChannelID == nil)
        #expect(guest.service.connectionState == .idle)
    }

    // MARK: - FND-1 hand-off (DSCN-28)

    @Test("Audio-lane loss schedules a reconnect through the control-lane path")
    @MainActor
    func audioLaneLossSchedulesReconnect() async throws {
        let h = try Harness(reconnectBaseDelay: .seconds(30))
        defer { h.close() }
        _ = try await discoverAndJoin(h)
        try await connectGuest(h)

        h.audioPlane.emit(.failed("Guide audio connection closed"))

        try await waitUntil("reconnect scheduled") { h.service.connectionState == .reconnecting(attempt: 1) }
        #expect(h.control.startGuestCalls == 1, "the lane restart waits for the ADR-034 backoff")
        #expect(h.control.clearSessionCalls == 1, "a reconnect keeps the credential (only the join's stopCurrentActivity cleared)")
    }

    @Test("Audio-lane loss during the control handshake is deferred until connected")
    @MainActor
    func audioLaneLossDuringConnectingIsDeferredUntilConnected() async throws {
        let h = try Harness(reconnectBaseDelay: .seconds(30))
        defer { h.close() }
        _ = try await discoverAndJoin(h)

        h.audioPlane.emit(.failed("Guide audio connection failed"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.service.connectionState == .connecting, "loss is pending while the control handshake runs")

        h.control.emit(.connected)

        try await waitUntil("reconnect scheduled after connect") {
            h.service.connectionState == .reconnecting(attempt: 1)
        }
    }

    // MARK: - FND-13

    @Test("Connected and audio-ready counts are independent")
    @MainActor
    func connectedAndAudioReadyCountsAreIndependent() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await createGuide(h)
        let guest = ParticipantSession(
            participantID: UUID(),
            connectionID: "a-1",
            displayName: "A",
            role: .guest,
            platform: .iOS
        )

        h.control.emit(.guestJoined(guest))
        try await waitUntil("connected count") { h.service.connectedGuestCount == 1 }
        #expect(h.service.listenerCount == 0)

        h.audioPlane.emit(.joined(guest))
        try await waitUntil("listener count") { h.service.listenerCount == 1 }

        // Re-registration arrives as disconnect + join and counts once.
        h.control.emit(.guestDisconnected(participantID: guest.participantID))
        h.control.emit(.guestJoined(guest))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.service.connectedGuestCount == 1)

        h.control.emit(.guestDisconnected(participantID: guest.participantID))
        try await waitUntil("disconnected count") { h.service.connectedGuestCount == 0 }
        #expect(h.service.listenerCount == 1)
    }

    @Test("Speaker output exposes the feedback warning only while listening")
    @MainActor
    func speakerOutputExposesFeedbackWarning() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await discoverAndJoin(h)
        #expect(h.service.speakerFeedbackWarning == nil)

        h.service.setListenerOutput(.speaker)
        #expect(h.service.speakerFeedbackWarning == ChannelService.speakerFeedbackWarningText)

        h.service.setListenerOutput(.privateAudio)
        #expect(h.service.speakerFeedbackWarning == nil)

        h.service.leaveChannel()
        h.service.setListenerOutput(.speaker)
        #expect(h.service.speakerFeedbackWarning == nil, "not listening")
    }

    @Test("Capture stream ending while broadcasting surfaces an error and keeps the lanes")
    @MainActor
    func captureStreamEndSurfacesError() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await createGuide(h)
        #expect(h.service.tourFeatureError == nil)

        h.engine.captureContinuation?.finish()

        try await waitUntil("capture error surfaced") {
            h.service.tourFeatureError == "Microphone capture stopped"
        }
        #expect(h.service.listenState == .broadcasting, "control and asset lanes stay up (DSCN-12)")
        #expect(h.control.clearSessionCalls == 0)
    }

    // MARK: - G5 FND-9

    /// Inits are side-effect free: `NetworkCoordinator`/`LocalControlPlane` store fields,
    /// `TourControlService(transport:)` only wraps the transport, `LocalGuidanceService()` creates
    /// no manager until `start()`, and the fake engine never touches AVAudioEngine.
    @Test("Asset transfer failure surfaces in tourFeatureError")
    @MainActor
    func assetTransferFailureSurfacesInTourFeatureError() async throws {
        let h = try Harness()
        defer { h.close() }
        #expect(h.service.tourFeatureError == nil)

        h.asset.emit(.failed("Asset lane failed"))

        try await waitUntil("asset failure surfaced", timeout: .seconds(2)) {
            h.service.tourFeatureError == "Asset lane failed"
        }
    }

    // MARK: - Helpers

    @MainActor
    private func createGuide(_ h: Harness) async throws -> Channel {
        h.service.createChannel(name: "Tour")
        try await waitUntil("broadcasting") { h.service.listenState == .broadcasting }
        return try #require(h.service.activeChannel)
    }

    /// Discovery must append the channel first: `scheduleReconnect` and the address-change path
    /// resolve through `channels`.
    @MainActor
    private func discoverAndJoin(_ h: Harness, hostIP: String = "10.0.0.1") async throws -> Channel {
        h.coordinator.start()
        h.service.startListening()
        let channelID = UUID().uuidString
        h.controlPlane.emit(.channelAnnounce(announce: BLECommand.ChannelAnnounce(
            channelID: channelID,
            channelName: "Tour",
            createdBy: UUID().uuidString,
            audioQuality: .standard,
            wifiSSID: nil,
            audioHostIP: hostIP
        )))
        try await waitUntil("discovered channel") { h.service.channels.contains { $0.id == channelID } }
        let channel = try #require(h.service.channels.first { $0.id == channelID })
        h.service.joinChannel(channel, tourCode: "23456789AB")
        try await waitUntil("guest transports started") {
            h.service.connectionState == .connecting
                && h.control.startGuestCalls >= 1
                && h.audioPlane.startListeningCalls >= 1
        }
        return channel
    }

    @MainActor
    private func connectGuest(_ h: Harness) async throws {
        h.control.emit(.connected)
        try await waitUntil("connected") { h.service.connectionState == .connected }
    }

    private func announce(_ channel: Channel, audioHostIP: String) -> BLECommand.ChannelAnnounce {
        BLECommand.ChannelAnnounce(
            channelID: channel.id,
            channelName: channel.name,
            createdBy: channel.createdBy,
            audioQuality: .standard,
            wifiSSID: nil,
            audioHostIP: audioHostIP
        )
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { throw TestTimeout.expired(description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
