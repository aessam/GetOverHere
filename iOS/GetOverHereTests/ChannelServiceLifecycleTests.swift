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
    @Test @MainActor func gatewayReconnectExhaustionCanBeRetriedWithoutNewEnrollment() async throws {
        let h = try Harness()
        let control = LocalControlPlane(displayName: "Gateway recovery fixture")
        var delays: [Duration] = []
        let gateway = GatewaySessionCoordinator(service: h.service, control: control,
            reconnectSleep: { delays.append($0); await Task.yield() })
        defer { gateway.stop(); control.stop(); h.service.terminate(); h.close() }
        // No wired interface exists in this simulator-only recovery fixture.
        #expect(gateway.wiredInterfaces.selected == nil)
        let offer = try GatewayPairingMessage(role: .offer, pairingID: UUID(), roomID: UUID(), guideID: UUID(),
            expiresAtMilliseconds: LiveWiredCompanionTransport.wallMilliseconds + 120_000,
            certificateFingerprint: Data(repeating: 1, count: 32), guideKeyFingerprint: Data(repeating: 2, count: 32),
            offerCertificateFingerprint: Data(repeating: 1, count: 32), host: "192.0.2.1", port: GatewayProtocol.servicePort)
        try gateway.receivePairingQR(offer.qrString)
        gateway.transport.onError?("Injected cable outage")
        for _ in 0..<1_000 {
            if gateway.state == "wired-reconnect-exhausted" { break }
            await Task.yield()
        }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)])
        #expect(gateway.state == "wired-reconnect-exhausted")
        #expect(throws: NearbyConnectionError.self) { try gateway.retryWiredConnection() }
        // Deliberate retry resets the budget even though the cable is still absent.
        gateway.transport.onError?("Still disconnected")
        for _ in 0..<1_000 {
            if delays.count == 10 && gateway.state == "wired-reconnect-exhausted" { break }
            await Task.yield()
        }
        #expect(delays.count == 10)
        #expect(gateway.offer?.pairingID == offer.pairingID)
    }

    @Test @MainActor
    func findNearbyDoesNotForceExperimentalAware() throws {
        let h = try Harness()
        h.service.findNearbyTours()
        #expect(h.service.bluetoothDiscoveryEnabled)
        #expect(!h.service.awareDiscoveryEnabled)
        h.service.awareDiscoveryEnabled = true
        h.service.findNearbyTours()
        #expect(h.service.awareDiscoveryEnabled, "Keep an explicit Aware choice")
        h.service.terminate()
    }

    private enum TestTimeout: Error {
        case expired(String)
    }

    @MainActor
    private final class Harness {
        let controlPlane: LifecycleControlPlane
        let audioPlane = LifecycleAudioPlane()
        let control = LifecycleControlTransport()
        let asset = LifecycleAssetTransport()
        let engine = FakeAudioEngine()
        let coordinator: NetworkCoordinator
        let service: ChannelService
        private let root: URL

        init(reconnectBaseDelay: Duration = .milliseconds(1), allowNearbyAdmission: Bool = false,
             admission: (any RoomAdmissionInterface)? = nil,
             controlPlane: LifecycleControlPlane? = nil,
             routedControlPlane: (any ControlPlane)? = nil) throws {
            let controlPlane = controlPlane ?? LifecycleControlPlane()
            self.controlPlane = controlPlane
            root = FileManager.default.temporaryDirectory.appending(
                path: "GetOverHereLifecycle-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            coordinator = NetworkCoordinator(
                displayName: "Local",
                controlPlane: routedControlPlane ?? controlPlane,
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
                roomAdmission: admission ?? LifecycleRoomAdmission(allowNearby: allowNearbyAdmission)
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

    @MainActor private final class HoldingNearbyControlPlane: ControlPlane, NearbyRouteControl {
        let base: LifecycleControlPlane
        var holdPreparation = false
        private(set) var heldPrepareCalls = 0
        private var continuation: CheckedContinuation<Void, Never>?
        init(base: LifecycleControlPlane) { self.base = base }
        var localPeer: PeerInfo { base.localPeer }
        var connectedPeers: [PeerInfo] { base.connectedPeers }
        var commands: AsyncStream<(BLECommand, PeerInfo)> { base.commands }
        var peerEvents: AsyncStream<PeerEvent> { base.peerEvents }
        var onNearbyError: ((String) -> Void)? {
            get { base.onNearbyError }
            set { base.onNearbyError = newValue }
        }
        var usesBluetoothGuestRoute: Bool { base.usesBluetoothGuestRoute }
        func start() { base.start() }
        func stop() { base.stop() }
        func broadcast(_ command: BLECommand) { base.broadcast(command) }
        func send(_ command: BLECommand, to peer: PeerInfo) { base.send(command, to: peer) }
        func setBluetoothDiscoveryMode(_ mode: BluetoothDiscoveryMode) { base.setBluetoothDiscoveryMode(mode) }
        func setAwareDiscoveryMode(_ mode: BluetoothDiscoveryMode) { base.setAwareDiscoveryMode(mode) }
        func canConnectNearby(roomID: UUID) -> Bool { base.canConnectNearby(roomID: roomID) }
        func stopNearbyGuest() { base.stopNearbyGuest() }
        func prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID) async throws -> NearbyGuestRoute {
            let prepared = try await base.prepareNearbyGuest(roomID: roomID, expectedGuideID: expectedGuideID)
            if holdPreparation {
                heldPrepareCalls += 1
                await withCheckedContinuation { continuation = $0 }
            }
            return prepared
        }
        func release() {
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    nonisolated private final class RouteAdmission: RoomAdmissionInterface, @unchecked Sendable {
        struct Call: Equatable {
            let host: String
            let room: UUID
            let guide: UUID
            let code: String?
        }
        private let lock = NSCondition()
        private var recorded: [Call] = []
        private var held: Bool
        private var finished = 0
        private let lanError: (any Error)?
        private let nearbyError: (any Error)?
        var calls: [Call] { lock.withLock { recorded } }
        var completedCalls: Int { lock.withLock { finished } }

        init(lanError: (any Error)? = RoomAdmissionConnectionError.unreachable,
             nearbyError: (any Error)? = nil, holdLAN: Bool = false) {
            self.lanError = lanError; self.nearbyError = nearbyError; held = holdLAN
        }
        func release() { lock.lock(); held = false; lock.broadcast(); lock.unlock() }
        func start(sessionID: UUID, sessionCode: String, signer: GuideFrameSigner) throws {}
        func update(policy: RoomAccessPolicy) throws {}
        func stop() {}
        func join(host: String, sessionID: UUID, expectedGuideID: UUID, code: String?) throws -> AdmittedRoomCredentials {
            lock.lock()
            recorded.append(Call(host: host, room: sessionID, guide: expectedGuideID, code: code))
            let deadline = Date().addingTimeInterval(5)
            while held && host != "127.0.0.1" {
                if !lock.wait(until: deadline) { lock.unlock(); throw TestTimeout.expired("held LAN admission") }
            }
            lock.unlock()
            defer { lock.withLock { finished += 1 } }
            if let error = host == "127.0.0.1" ? nearbyError : lanError { throw error }
            return try LifecycleRoomAdmission(allowNearby: true).join(host: host, sessionID: sessionID,
                expectedGuideID: expectedGuideID, code: code)
        }
    }

    @Test("Unreachable advertised LAN admits once over the matching nearby route and starts every lane")
    @MainActor
    func unreachableLANFallsBackToNearby() async throws {
        let admission = RouteAdmission()
        let h = try Harness(admission: admission)
        defer { h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = try await discoverAndJoin(h)
        #expect(admission.calls.map(\.host) == ["10.0.0.1", "127.0.0.1"])
        #expect(admission.calls.allSatisfy { $0.room.uuidString == channel.id && $0.guide.uuidString == channel.createdBy && $0.code == "23456789AB" })
        #expect(h.controlPlane.nearbyPrepareCalls == 1)
        #expect(h.controlPlane.usesBluetoothGuestRoute)
        #expect(h.service.guestRoute?.adapterHost == "127.0.0.1")
        #expect(h.control.startGuestHostIPs == ["127.0.0.1"])
        #expect(h.asset.hostIP == "127.0.0.1")
        #expect(h.audioPlane.startListeningCalls == 1)
    }

    @Test("Admission rejection never retries the code on another route", arguments: 0..<6)
    @MainActor
    func terminalLANAdmissionNeverFallsBack(kind: Int) async throws {
        let errors: [any Error] = [RoomAdmissionError.invalidCode, RoomAdmissionError.locked,
            RoomAdmissionError.invalidMessage, RoomAdmissionV2Error.wrongGuide,
            RoomAdmissionV2Error.incompatibleVersion, RoomAdmissionV2Error.guideChanged]
        let admission = RouteAdmission(lanError: errors[kind])
        let h = try Harness(admission: admission)
        defer { h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = Channel(id: UUID().uuidString, name: "Room", createdAt: .now,
            createdBy: UUID().uuidString, audioHostIP: "10.0.0.1", roomAdmissionVersion: 2)
        h.service.joinChannel(channel, tourCode: "WrongCode")
        try await waitUntil("terminal admission failure") { h.service.connectionState == .failed }
        #expect(admission.calls.count == 1)
        #expect(h.controlPlane.nearbyPrepareCalls == 0)
        #expect(h.control.startGuestCalls == 0)
    }

    @Test("Failed nearby admission does not loop back to LAN or retry the code")
    @MainActor
    func nearbyAdmissionFallbackIsBounded() async throws {
        let admission = RouteAdmission(nearbyError: RoomAdmissionConnectionError.unreachable)
        let h = try Harness(admission: admission)
        defer { h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = Channel(id: UUID().uuidString, name: "Room", createdAt: .now,
            createdBy: UUID().uuidString, audioHostIP: "10.0.0.1", roomAdmissionVersion: 2)
        h.service.joinChannel(channel, tourCode: "Code")
        try await waitUntil("bounded fallback failure") { h.service.connectionState == .failed }
        #expect(admission.calls.map(\.host) == ["10.0.0.1", "127.0.0.1"])
        #expect(h.controlPlane.nearbyPrepareCalls == 1)
        #expect(!h.controlPlane.usesBluetoothGuestRoute)
        #expect(h.control.startGuestCalls == 0)
    }

    @Test("Cancel or replacement during LAN admission cannot start stale nearby fallback", arguments: [false, true])
    @MainActor
    func staleLANFailureDoesNotPrepareNearby(replace: Bool) async throws {
        let admission = RouteAdmission(holdLAN: true)
        let h = try Harness(admission: admission)
        defer { admission.release(); h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = Channel(id: UUID().uuidString, name: "Old", createdAt: .now,
            createdBy: UUID().uuidString, audioHostIP: "10.0.0.1", roomAdmissionVersion: 2)
        h.service.joinChannel(channel, tourCode: "OldCode")
        try await waitUntil("LAN admission entered") { admission.calls.count == 1 }
        h.service.cancelJoin()
        if replace {
            let next = Channel(id: UUID().uuidString, name: "New", createdAt: .now,
                createdBy: UUID().uuidString, roomAdmissionVersion: 2)
            h.service.joinChannel(next, tourCode: "NewCode")
            try await waitUntil("replacement joined") { h.control.startGuestCalls == 1 }
        }
        admission.release()
        try await waitUntil("old admission completed") { admission.completedCalls == (replace ? 2 : 1) }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.controlPlane.nearbyPrepareCalls == (replace ? 1 : 0))
        #expect(h.control.startGuestCalls == (replace ? 1 : 0))
        #expect(replace ? h.service.activeChannel?.name == "New" || h.service.activeChannelID != nil : h.service.connectionState == .idle)
    }

    @Test("Cancel before the join task starts cannot send credentials or restore its join stage")
    @MainActor
    func canceledQueuedJoinNeverStartsAdmission() async throws {
        let admission = RouteAdmission()
        let h = try Harness(admission: admission)
        defer { h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = Channel(id: UUID().uuidString, name: "Canceled", createdAt: .now,
            createdBy: UUID().uuidString, audioHostIP: "10.0.0.1", roomAdmissionVersion: 2)

        // Both calls execute in this MainActor turn, before the unstructured join task can run.
        h.service.joinChannel(channel, tourCode: "NeverSendThisCode")
        h.service.cancelJoin()
        #expect(h.service.connectionState == .idle)
        #expect(h.service.joinStage == nil)
        // Drain actor work before checking the absence of transport work and stale UI mutation.
        for _ in 0..<20 { await Task.yield() }
        #expect(admission.calls.isEmpty)
        #expect(h.service.connectionState == .idle)
        #expect(h.service.joinStage == nil)
        #expect(h.controlPlane.nearbyPrepareCalls == 0)
        #expect(h.control.startGuestCalls == 0)
    }

    @Test("Nearby ownership survives LAN announcements and a route recovery retry")
    @MainActor
    func nearbyRouteSurvivesLANAnnouncementAndReconnect() async throws {
        let h = try Harness(reconnectBaseDelay: .milliseconds(10), allowNearbyAdmission: true)
        defer { h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = try await discoverAndJoin(h, hostIP: nil)
        try await connectGuest(h)
        let route = try #require(h.service.guestRoute)
        let stops = h.controlPlane.nearbyStopCalls
        h.controlPlane.emit(.channelAnnounce(announce: announce(channel, audioHostIP: "10.0.0.9")))
        try await waitUntil("LAN announcement applied") { h.service.activeChannel?.audioHostIP == "10.0.0.9" }
        #expect(h.control.startGuestCalls == 1)
        #expect(h.service.guestRoute == route)
        h.controlPlane.nearbyPrepareError = NearbyConnectionError.unavailable
        h.control.emit(.failed("Connection lost"))
        try await waitUntil("nearby recovery attempted") { h.controlPlane.nearbyPrepareCalls >= 2 }
        h.service.retryAudio()
        #expect(h.audioPlane.startListeningCalls == 1, "Audio-only retry cannot use rejected LAN metadata while nearby is unavailable")
        h.controlPlane.nearbyPrepareError = nil
        try await waitUntil("nearby recovery completed") { h.control.startGuestCalls == 2 }
        #expect(h.service.guestRoute == route)
        #expect(h.control.startGuestHostIPs == ["127.0.0.1", "127.0.0.1"])
        #expect(h.asset.hostIP == "127.0.0.1")
        #expect(h.controlPlane.nearbyStopCalls == stops)
    }

    @Test("Retry Audio cannot reopen an old adapter while native recovery is suspended")
    @MainActor
    func retryAudioWaitsForSuspendedNearbyRecovery() async throws {
        let base = LifecycleControlPlane()
        base.nearbyAvailable = true
        let holding = HoldingNearbyControlPlane(base: base)
        let h = try Harness(allowNearbyAdmission: true, controlPlane: base, routedControlPlane: holding)
        defer { holding.release(); h.service.terminate(); h.close() }
        _ = try await discoverAndJoin(h, hostIP: nil)
        try await connectGuest(h)
        let previousRoute = try #require(h.service.guestRoute)
        let starts = h.audioPlane.startListeningCalls
        holding.holdPreparation = true
        h.control.emit(.disconnected)
        try await waitUntil("native route probe suspended") { holding.heldPrepareCalls == 1 }

        #expect(h.service.guestRoute == previousRoute)
        h.service.retryAudio()
        for _ in 0..<20 { await Task.yield() }
        #expect(holding.heldPrepareCalls == 1)
        #expect(h.audioPlane.startListeningCalls == starts)
        #expect(h.control.startGuestCalls == 1)

        holding.release()
        try await waitUntil("recovered nearby lanes restarted") { h.control.startGuestCalls == 2 }
        #expect(h.audioPlane.startListeningCalls == starts + 1)
        #expect(h.service.guestRoute == previousRoute)
        #expect(h.service.connectionState == .connecting)
        h.control.emit(.connected)
        try await waitUntil("replacement lanes authenticated") { h.service.connectionState == .connected }
    }

    @Test("Loss of LAN discovery permits reconnecting retained credentials over nearby")
    @MainActor
    func LANSessionRecoversToNearbyWhenLANDisappears() async throws {
        let h = try Harness(allowNearbyAdmission: true)
        defer { h.service.terminate(); h.close() }
        h.controlPlane.nearbyAvailable = true
        let channel = try await discoverAndJoin(h)
        try await connectGuest(h)
        h.controlPlane.emit(.channelAnnounce(announce: announce(channel, audioHostIP: nil)))
        try await waitUntil("LAN route withdrawn") { h.service.activeChannel?.audioHostIP == nil }
        h.control.emit(.disconnected)
        try await waitUntil("nearby replacement lanes started") { h.control.startGuestCalls == 2 }
        #expect(h.control.startGuestHostIPs == ["10.0.0.1", "127.0.0.1"])
        #expect(h.service.guestRoute?.adapterHost == "127.0.0.1")
        #expect(h.asset.hostIP == "127.0.0.1")
        #expect(h.audioPlane.startListeningCalls == 2)
    }

    @Test("A failed nearby admission closes its route and permits another attempt")
    @MainActor
    func failedNearbyAdmissionClosesRoute() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        let channel = Channel(id: UUID().uuidString, name: "Nearby", createdAt: .now,
                              createdBy: UUID().uuidString, roomAdmissionVersion: 2)
        #expect(!h.service.canJoin(channel))
        h.controlPlane.nearbyAvailable = true
        #expect(h.service.canJoin(channel))
        let stops = h.controlPlane.nearbyStopCalls
        h.service.joinChannel(channel, tourCode: "")
        try await waitUntil("failed nearby admission") { h.service.connectionState == .failed }
        #expect(h.controlPlane.nearbyStopCalls == stops + 1)
        #expect(!h.controlPlane.usesBluetoothGuestRoute)
        #expect(h.control.startGuestCalls == 0)
        h.service.leaveChannel()
        #expect(h.service.connectionState == .idle)
        h.service.joinChannel(channel, tourCode: "")
        try await waitUntil("second nearby admission failure") { h.service.connectionState == .failed }
        #expect(h.controlPlane.nearbyPrepareCalls == 2)
    }

    @Test("Bluetooth discovery requires intent and stops for a LAN guest or background")
    @MainActor
    func bluetoothDiscoveryLifecycle() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        #expect(h.controlPlane.bluetoothMode == .off)
        h.service.bluetoothDiscoveryEnabled = true
        #expect(h.controlPlane.bluetoothMode == .browsing)
        h.service.discoveryForeground = false
        #expect(h.controlPlane.bluetoothMode == .off)
        h.service.discoveryForeground = true
        #expect(h.controlPlane.bluetoothMode == .browsing)
        _ = try await discoverAndJoin(h)
        #expect(h.controlPlane.bluetoothMode == .off)
        h.service.leaveChannel()
        #expect(h.controlPlane.bluetoothMode == .browsing)
        h.service.bluetoothDiscoveryEnabled = false
        #expect(h.controlPlane.bluetoothMode == .off)
    }

    @Test("Creating a tour activates nearby advertising without an extra settings step")
    @MainActor
    func bluetoothGuideLifecycle() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        #expect(h.controlPlane.bluetoothMode == .off)
        _ = try await createGuide(h)
        #expect(h.controlPlane.bluetoothMode == .advertising)
        h.service.discoveryForeground = false
        // A joined tour keeps its Bluetooth listener alive when the guide locks the phone.
        #expect(h.controlPlane.bluetoothMode == .advertising)
        h.service.discoveryForeground = true
        #expect(h.controlPlane.bluetoothMode == .advertising)
    }

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

    @Test("A failed nearby route is retried with a bound, without restarting a closed adapter")
    @MainActor
    func nearbyRouteRecoveryExhaustionStopsCleanly() async throws {
        let h = try Harness(allowNearbyAdmission: true)
        defer { h.close() }
        h.controlPlane.nearbyAvailable = true
        _ = try await discoverAndJoin(h, hostIP: nil)
        try await connectGuest(h)
        h.controlPlane.nearbyPrepareError = NearbyConnectionError.unavailable
        h.control.emit(.disconnected)
        try await waitUntil("nearby route attempts exhausted") { h.service.connectionState == .failed }
        #expect(h.controlPlane.nearbyPrepareCalls == 6)
        #expect(h.control.startGuestCalls == 1, "failed route preparation cannot restart a stale loopback adapter")
        #expect(h.service.guestRoute == nil)
    }

    @Test("Nearby identity mismatch is terminal; healthy recovery preserves route ownership", arguments: [false, true])
    @MainActor
    func nearbyRecoveryPreservesRouteOrRejectsIdentity(mismatch: Bool) async throws {
        let h = try Harness(allowNearbyAdmission: true)
        defer { h.close() }
        h.controlPlane.nearbyAvailable = true
        _ = try await discoverAndJoin(h, hostIP: nil)
        try await connectGuest(h)
        let route = try #require(h.service.guestRoute)
        let stops = h.controlPlane.nearbyStopCalls
        if mismatch { h.controlPlane.nearbyPrepareError = RoomAdmissionV2Error.wrongGuide }
        h.control.emit(.disconnected)
        if mismatch {
            try await waitUntil("nearby identity rejected") { h.service.connectionState == .failed }
            #expect(h.controlPlane.nearbyPrepareCalls == 2)
            #expect(h.control.startGuestCalls == 1)
            #expect(h.service.tourFeatureError == RoomAdmissionV2Error.wrongGuide.localizedDescription)
        } else {
            try await waitUntil("nearby lanes recovered") { h.control.startGuestCalls == 2 }
            #expect(h.service.guestRoute == route)
            #expect(h.controlPlane.nearbyStopCalls == stops)
        }
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

    @Test("An old duplicate connected event cannot cancel audio recovery during backoff")
    @MainActor
    func duplicateConnectedDuringBackoffDoesNotCancelRecovery() async throws {
        let h = try Harness(reconnectBaseDelay: .seconds(30))
        defer { h.service.terminate(); h.close() }
        _ = try await discoverAndJoin(h)
        try await connectGuest(h)
        h.audioPlane.emit(.failed("Old audio lane failed"))
        try await waitUntil("audio recovery scheduled") { h.service.connectionState == .reconnecting(attempt: 1) }

        // The old control lane has not stopped yet. Its duplicate must not acknowledge a new run.
        h.control.emit(.connected)
        for _ in 0..<20 { await Task.yield() }
        #expect(h.service.connectionState == .reconnecting(attempt: 1))
        #expect(h.control.startGuestCalls == 1)
        #expect(h.audioPlane.startListeningCalls == 1)
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
            h.service.audioRuntimeError == "Microphone capture stopped"
        }
        #expect(h.service.audioRuntimeState == .failed)
        #expect(h.service.listenState == .broadcasting, "control and asset lanes stay up (DSCN-12)")
        #expect(h.control.clearSessionCalls == 0)
        h.service.restartMicrophone()
        #expect(h.service.audioRuntimeState == .running)
        #expect(h.service.audioRuntimeError == nil)
        #expect(h.engine.startCaptureCalls == 2)
        #expect(h.control.startGuideCalls == 1)
        #expect(h.audioPlane.startBroadcastingCalls == 1)
    }

    @Test("A connected guest waits for renderer acceptance before showing audio running")
    @MainActor
    func audioReadinessRequiresRendererAcceptance() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        _ = try await discoverAndJoin(h)
        try await connectGuest(h)
        #expect(h.service.audioRuntimeState == .starting)
        h.audioPlane.audioHandler?(Data([0, 0, 1, 0]))
        try await waitUntil("renderer accepted audio") { h.service.audioRuntimeState == .running }
        #expect(h.engine.played.count == 1)
    }

    @Test("Playback startup failure keeps room lanes and Retry Audio does not readmit")
    @MainActor
    func playbackFailureCanRetryWithoutRejoiningRoom() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        // Join normally, then use the same retry entry point to inject a renderer start failure.
        let channel = try await discoverAndJoin(h)
        try await connectGuest(h)
        h.engine.startPlaybackError = AudioEngineError.playbackStartFailed("Renderer unavailable")
        h.service.retryAudio()
        #expect(h.service.audioRuntimeState == .failed)
        #expect(h.service.audioRuntimeError != nil)
        #expect(h.service.connectionState == .connected)
        #expect(h.service.activeChannelID == channel.id)
        #expect(h.control.startGuestCalls == 1)
        #expect(h.asset.startGuestCalls == 1)
        let failedRun = h.engine.onRuntimeEvent
        h.engine.startPlaybackError = nil
        h.service.retryAudio()
        #expect(h.service.audioRuntimeState == .starting)
        failedRun?(.failed(.playback, "Stale renderer failure"))
        #expect(h.service.audioRuntimeError == nil)
        h.audioPlane.audioHandler?(Data([0, 0]))
        try await waitUntil("audio retry accepted") { h.service.audioRuntimeState == .running }
        #expect(h.control.startGuestCalls == 1)
        #expect(h.asset.startGuestCalls == 1)
    }

    @Test("Audio callbacks queued before Leave cannot revive the old session")
    @MainActor
    func staleAudioCallbackCannotReviveLeftRoom() async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        _ = try await discoverAndJoin(h)
        let oldCallback = h.engine.onRuntimeEvent
        let oldPCM = h.audioPlane.audioHandler
        h.service.leaveChannel()
        oldCallback?(.firstPlaybackBufferAccepted)
        oldPCM?(Data([0, 0]))
        await Task.yield()
        #expect(h.service.audioRuntimeState == .idle)
        #expect(h.engine.played.isEmpty)
    }

    @Test("Old guide callbacks cannot fail a replacement guide or guest", arguments: [false, true])
    @MainActor
    func oldGuideCallbackCannotAffectReplacement(becomeGuest: Bool) async throws {
        let h = try Harness()
        defer { h.service.terminate(); h.close() }
        h.service.createChannel(name: "First guide")
        try await waitUntil("first guide") { h.service.listenState == .broadcasting }
        let oldHandler = try #require(h.audioPlane.handler)
        h.service.leaveChannel()
        if becomeGuest {
            _ = try await discoverAndJoin(h)
        } else {
            h.service.createChannel(name: "Replacement guide")
            try await waitUntil("replacement guide") { h.service.listenState == .broadcasting }
        }
        let replacement = h.service.activeChannelID
        oldHandler(.failed("Stale guide transport failure"))
        oldHandler(.joined(ParticipantSession(participantID: UUID(), connectionID: "stale-guide",
            displayName: "Old guest", role: .guest, platform: .iOS)))
        // Synchronize with the queued MainActor delivery, not a radio or wall-clock delay.
        await Task { @MainActor in }.value
        #expect(h.service.activeChannelID == replacement)
        #expect(h.service.connectionState != .failed)
        #expect(h.service.tourFeatureError == nil)
        #expect(h.service.listenerCount == 0)
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
        _ = try await discoverAndJoin(h)

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
    private func discoverAndJoin(_ h: Harness, hostIP: String? = "10.0.0.1") async throws -> Channel {
        h.coordinator.start()
        h.service.startListening()
        let channelID = UUID().uuidString
        h.controlPlane.emit(.channelAnnounce(announce: BLECommand.ChannelAnnounce(
            channelID: channelID,
            channelName: "Tour",
            createdBy: UUID().uuidString,
            audioQuality: .standard,
            wifiSSID: nil,
            audioHostIP: hostIP,
            roomAdmissionVersion: 2,
            isRoomLocked: false
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

    private func announce(_ channel: Channel, audioHostIP: String?) -> BLECommand.ChannelAnnounce {
        BLECommand.ChannelAnnounce(
            channelID: channel.id,
            channelName: channel.name,
            createdBy: channel.createdBy,
            audioQuality: .standard,
            wifiSSID: nil,
            audioHostIP: audioHostIP,
            roomAdmissionVersion: channel.roomAdmissionVersion,
            isRoomLocked: channel.isRoomLocked
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
