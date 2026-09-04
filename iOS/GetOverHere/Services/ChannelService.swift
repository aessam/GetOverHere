import Foundation
import os
import TourSessionCore

enum OfflineMapStatus: Equatable {
    case unavailable
    case transferring
    case ready
    case failed(String)
}

/// Coordinates the guide's audio, presentation, and tour assets for one local session.
/// - Creator of a channel is the ONLY speaker
/// - Everyone else listens
/// - Bonjour handles discovery on the shared local network
/// - Independent authenticated TCP lanes carry audio, control, and assets
@Observable
final class ChannelService {

    // MARK: - State

    private(set) var channels: [Channel] = []
    var activeChannelID: String?

    enum ListenState: Equatable {
        case idle
        case listening
        case broadcasting
    }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed
    }

    private(set) var listenState: ListenState = .idle
    private(set) var listenerCount: Int = 0
    private(set) var listenerOutput: ListenerOutput = .privateAudio
    private(set) var isImportingSlides = false
    private(set) var isImportingMap = false
    private(set) var offlineMapConfiguration: OfflineMapConfiguration?
    private(set) var offlineMapStatus: OfflineMapStatus = .unavailable
    private(set) var tourFeatureError: String?
    private(set) var tourCode: String?
    private(set) var connectionState: ConnectionState = .idle
    var audioQuality: AudioQuality = .standard

    struct SlideImport: Sendable {
        let data: Data
        let mimeType: String
    }

    // MARK: - Dependencies

    private let coordinator: NetworkCoordinator
    private let audioEngine: any AudioEngineInterface
    /// Base of the ADR-034 exponential reconnect backoff; tests shorten it (DSCN-23).
    private let reconnectBaseDelay: Duration
    let tourControlService: TourControlService
    let assetTransferService: TourAssetTransferService
    let contentStore: TourContentStore
    let localGuidanceService: LocalGuidanceService
    private var captureTask: Task<Void, Never>?
    private var listenTasks: [Task<Void, Never>] = []
    private var participantRegistry = ParticipantRegistry()
    private var guestCredential: SessionCredential?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    /// Monotonic guard for continuations that resume after the off-main credential stretch (DSCN-20).
    private var sessionAttempt: UInt64 = 0
    /// Lane-ownership generation: bumped only where the lanes change hands (a session start,
    /// `stopCurrentActivity`, an End Tour, or termination). The deferred End Tour teardown compares
    /// it, never `sessionAttempt`, so a no-op leave, terminate, or invalid join cannot skip it (ADR-048).
    private var sessionGeneration: UInt64 = 0
    /// An audio-lane loss observed before the control lane connected; consumed on `.connected` (ADR-044).
    private var pendingAudioLaneFailure: String?
    /// Audio-lane losses since the last delivered PCM buffer; terminal at 5 (DSCN-19).
    private var consecutiveAudioLaneFailures = 0

    // MARK: - Computed

    var activeChannel: Channel? {
        channels.first { $0.id == activeChannelID }
    }

    var isCreator: Bool {
        guard let ch = activeChannel else { return false }
        return ch.createdBy == coordinator.controlPlane.localPeer.id
    }

    var connectedPeers: [PeerInfo] {
        coordinator.controlPlane.connectedPeers
    }

    var localPeer: PeerInfo {
        coordinator.controlPlane.localPeer
    }

    /// Guests admitted on the control lane; independent of the audio-lane `listenerCount` (FND-13).
    var connectedGuestCount: Int {
        tourControlService.connectedGuestCount
    }

    static let speakerFeedbackWarningText =
        "Speaker output can feed back into the guide's microphone. Use the earpiece or headphones near the guide."

    /// Non-nil only while listening on the loudspeaker in a non-failed session (FND-13).
    var speakerFeedbackWarning: String? {
        listenState == .listening && listenerOutput == .speaker && connectionState != .failed
            ? Self.speakerFeedbackWarningText
            : nil
    }

    // MARK: - Init

    init(
        coordinator: NetworkCoordinator,
        audioEngine: any AudioEngineInterface,
        tourControlService: TourControlService,
        assetTransferService: TourAssetTransferService,
        contentStore: TourContentStore,
        localGuidanceService: LocalGuidanceService,
        reconnectBaseDelay: Duration = .seconds(1)
    ) {
        self.coordinator = coordinator
        self.audioEngine = audioEngine
        self.reconnectBaseDelay = reconnectBaseDelay
        self.tourControlService = tourControlService
        self.assetTransferService = assetTransferService
        self.contentStore = contentStore
        self.localGuidanceService = localGuidanceService
        assetTransferService.setEventHandler { [weak self, tourControlService] event in
            Task { @MainActor [weak self] in
                switch event {
                case let .manifestReceived(manifest):
                    tourControlService.acceptTourPack(manifest)
                    self?.refreshOfflineMap()
                case .assetReady:
                    self?.refreshOfflineMap()
                case .participantReady:
                    break
                case .failed:
                    Logger.channel.error("Tour asset transfer failed")
                }
            }
        }
        tourControlService.setConnectionEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handleControlConnectionEvent(event) }
        }
    }

    func startListening() {
        listenForChannelCommands()
        listenForPeerEvents()
        startPeriodicBroadcast()
        Logger.channel.info("ChannelService started")
    }

    // MARK: - Channel Management

    func createChannel(name: String) {
        sessionAttempt &+= 1
        let channel = Channel(
            id: UUID().uuidString,
            name: name,
            createdAt: Date(),
            createdBy: coordinator.controlPlane.localPeer.id
        )
        guard let sessionID = UUID(uuidString: channel.id),
              let participantID = UUID(uuidString: coordinator.controlPlane.localPeer.id) else {
            Logger.channel.error("Cannot create session with non-UUID channel or participant identity")
            return
        }

        let code = SessionCredential.generateShortCode()
        let attempt = sessionAttempt
        Task { [weak self] in
            guard let self else { return }
            let credential: SessionCredential
            do {
                credential = try await Self.stretchCredential(shortCode: code, sessionID: sessionID)
            } catch {
                guard attempt == sessionAttempt else {
                    Logger.channel.info("Discarding a stale guide credential failure; the session was replaced during the stretch")
                    return
                }
                tourCode = nil
                tourFeatureError = error.localizedDescription
                Logger.channel.error("Cannot derive the tour credential")
                return
            }
            guard attempt == sessionAttempt else {
                Logger.channel.info("Discarding a stale guide credential; the session was replaced during the stretch")
                return
            }
            startGuideSession(
                channel: channel,
                sessionID: sessionID,
                participantID: participantID,
                code: code,
                credential: credential
            )
        }
    }

    private func startGuideSession(
        channel: Channel,
        sessionID: UUID,
        participantID: UUID,
        code: String,
        credential: SessionCredential
    ) {
        do {
            try contentStore.beginPack(packID: sessionID, displayName: channel.name)
            let emptyManifest = try contentStore.manifestPayload()
            sessionGeneration &+= 1
            tourControlService.configureSession(
                sessionID: sessionID,
                participantID: participantID,
                displayName: coordinator.controlPlane.localPeer.displayName,
                platform: .iOS,
                credential: credential
            )
            assetTransferService.configureSession(
                sessionID: sessionID,
                participantID: participantID,
                displayName: coordinator.controlPlane.localPeer.displayName,
                platform: .iOS,
                credential: credential
            )
            // Every lane start is synchronous and throwing (ADR-046); nothing is committed or
            // published until control, asset, audio, and microphone capture are all running.
            try tourControlService.startGuide(deckID: sessionID)
            try assetTransferService.startGuideWithEmptyTourPack(emptyManifest)

            let plane = coordinator.selectAudioPlane()
            participantRegistry = ParticipantRegistry()
            listenerCount = 0
            plane.configureSession(
                sessionID: sessionID,
                participantID: participantID,
                displayName: coordinator.controlPlane.localPeer.displayName,
                platform: .iOS,
                credential: credential
            )
            plane.setSessionEventHandler { [weak self] event in
                guard let self else { return }
                Task { @MainActor [self] in self.handleAudioSessionEvent(event) }
            }
            try plane.startBroadcasting(channelID: channel.id, quality: audioQuality)
            try startCapturing(plane: plane, channelID: channel.id)

            offlineMapConfiguration = nil
            offlineMapStatus = .unavailable
            tourFeatureError = nil
            tourCode = code

            channels.append(channel)
            activeChannelID = channel.id
            listenState = .broadcasting
            connectionState = .connected
            guestCredential = nil

            broadcastChannelAnnounce(channel)
        } catch {
            rollbackFailedGuideSession(channelID: channel.id)
            tourCode = nil
            tourFeatureError = error.localizedDescription
            Logger.channel.error("Cannot start tour features")
            return
        }

        Logger.channel.info("Created megaphone (quality: \(self.audioQuality.label))")
    }

    func joinChannel(_ channel: Channel, tourCode rawTourCode: String) {
        sessionAttempt &+= 1
        guard let sessionID = UUID(uuidString: channel.id),
              let participantID = UUID(uuidString: coordinator.controlPlane.localPeer.id) else {
            Logger.channel.error("Cannot join session with non-UUID channel or participant identity")
            return
        }
        let normalizedCode = SessionCredential.normalize(rawTourCode)
        guard let hostIP = channel.audioHostIP else {
            tourFeatureError = "Guide network address is unavailable"
            Logger.channel.error("Cannot join session without a guide network address")
            return
        }
        let attempt = sessionAttempt
        Task { [weak self] in
            guard let self else { return }
            let credential: SessionCredential
            do {
                credential = try await Self.stretchCredential(shortCode: normalizedCode, sessionID: sessionID)
            } catch {
                guard attempt == sessionAttempt else {
                    Logger.channel.info("Discarding a stale guest credential failure; the session was replaced during the stretch")
                    return
                }
                tourFeatureError = error.localizedDescription
                return
            }
            guard attempt == sessionAttempt else {
                Logger.channel.info("Discarding a stale guest credential; the session was replaced during the stretch")
                return
            }
            startGuestSession(
                channel: channel,
                hostIP: hostIP,
                sessionID: sessionID,
                participantID: participantID,
                normalizedCode: normalizedCode,
                credential: credential
            )
        }
    }

    private func startGuestSession(
        channel: Channel,
        hostIP: String,
        sessionID: UUID,
        participantID: UUID,
        normalizedCode: String,
        credential: SessionCredential
    ) {
        stopCurrentActivity()
        offlineMapConfiguration = nil
        offlineMapStatus = .transferring
        tourFeatureError = nil
        tourCode = normalizedCode
        guestCredential = credential
        reconnectAttempt = 0
        activeChannelID = channel.id
        listenState = .listening
        connectionState = .connecting
        setListenerOutput(.privateAudio)
        sessionGeneration &+= 1
        startGuestTransports(
            channel: channel,
            hostIP: hostIP,
            sessionID: sessionID,
            participantID: participantID,
            credential: credential
        )

        Logger.channel.info("Joined megaphone")
    }

    func importSlides(_ imports: [SlideImport]) async {
        guard listenState == .broadcasting, !imports.isEmpty else { return }
        isImportingSlides = true
        defer { isImportingSlides = false }
        do {
            for item in imports {
                _ = try await contentStore.importSlide(data: item.data, mimeType: item.mimeType)
            }
            let manifest = try contentStore.manifestPayload()
            try await assetTransferService.hostTourPack(
                manifest,
                sourcesByAssetID: contentStore.sourcesByAssetID
            )
            try tourControlService.updateDeck(deckID: manifest.packID, slides: manifest.assets)
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
            Logger.channel.error("Slide import failed")
        }
    }

    func moveSlide(assetID: String, to destinationIndex: Int) async {
        guard listenState == .broadcasting else { return }
        do {
            try contentStore.moveSlide(assetID: assetID, to: destinationIndex)
            try await publishCurrentTourPack()
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
            Logger.channel.error("Slide reorder failed")
        }
    }

    func removeSlide(assetID: String) async {
        guard listenState == .broadcasting else { return }
        do {
            try contentStore.removeSlide(assetID: assetID)
            try await publishCurrentTourPack()
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
            Logger.channel.error("Slide removal failed")
        }
    }

    func importOfflineMap(styleURL: URL, archiveURL: URL) async {
        guard listenState == .broadcasting else { return }
        isImportingMap = true
        offlineMapStatus = .transferring
        defer { isImportingMap = false }
        let styleAccess = styleURL.startAccessingSecurityScopedResource()
        let archiveAccess = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if styleAccess { styleURL.stopAccessingSecurityScopedResource() }
            if archiveAccess { archiveURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let styleData = try Data(contentsOf: styleURL, options: [.mappedIfSafe])
            try await contentStore.importOfflineMap(styleData: styleData, archiveURL: archiveURL)
            let manifest = try contentStore.manifestPayload()
            try await assetTransferService.hostTourPack(
                manifest,
                sourcesByAssetID: contentStore.sourcesByAssetID
            )
            try tourControlService.updateDeck(deckID: manifest.packID, slides: manifest.assets)
            refreshOfflineMap()
            tourFeatureError = nil
        } catch {
            offlineMapStatus = .failed(error.localizedDescription)
            tourFeatureError = error.localizedDescription
            Logger.channel.error("Offline map import failed")
        }
    }

    func showSlide(assetID: String? = nil) {
        do {
            try tourControlService.showSlide(assetID: assetID)
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
        }
    }

    func hideSlides() {
        do { try tourControlService.hide() }
        catch { tourFeatureError = error.localizedDescription }
    }

    func previousSlide() {
        do { try tourControlService.goPrevious() }
        catch { tourFeatureError = error.localizedDescription }
    }

    func nextSlide() {
        do { try tourControlService.goNext() }
        catch { tourFeatureError = error.localizedDescription }
    }

    func setVisualFocus(_ mode: TourVisualMode) {
        do {
            try tourControlService.setVisualFocus(mode)
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
        }
    }

    func setTarget(latitude: Double, longitude: Double, label: String = "") {
        do {
            try tourControlService.setTarget(latitude: latitude, longitude: longitude, label: label)
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
        }
    }

    func clearTarget() {
        do { try tourControlService.clearTarget() }
        catch { tourFeatureError = error.localizedDescription }
    }

    func shareCurrentBearing() {
        do {
            guard let heading = localGuidanceService.magneticHeadingDegrees else {
                throw PresentationServiceError.invalidBearing
            }
            try tourControlService.shareBearing(degrees: heading)
            tourFeatureError = nil
        } catch {
            tourFeatureError = error.localizedDescription
        }
    }

    func clearBearing() {
        do { try tourControlService.clearBearing() }
        catch { tourFeatureError = error.localizedDescription }
    }

    func setListenerOutput(_ output: ListenerOutput) {
        listenerOutput = output
        audioEngine.listenerOutput = output
    }

    func leaveChannel() {
        sessionAttempt &+= 1
        guard let ch = activeChannel else { return }
        let isGuide = ch.createdBy == coordinator.controlPlane.localPeer.id
        sessionGeneration &+= 1
        let generation = sessionGeneration
        if isGuide {
            // UI state ends now; the authenticated leave is flushed off the main actor and the lanes
            // are cleared after delivery unless a newer session took over the lanes (ADR-048).
            audioEngine.stopCapture()
            captureTask?.cancel()
            captureTask = nil
            channels.removeAll { $0.id == ch.id }
            activeChannelID = nil
            listenState = .idle
            tourCode = nil
            connectionState = .idle
            participantRegistry = ParticipantRegistry()
            listenerCount = 0
            coordinator.controlPlane.broadcast(.channelEnded(channelID: ch.id))
            Task { [weak self] in
                do {
                    try await self?.tourControlService.endGuideSession()
                } catch {
                    Logger.channel.error("Failed to send authenticated session end (\(String(describing: type(of: error))))")
                }
                guard let self else { return }
                guard self.sessionGeneration == generation else {
                    Logger.channel.info("Skipping the deferred lane teardown; a newer session owns the lanes")
                    return
                }
                // This leave already invalidated older stretches; a create/join started inside the
                // flush window is the user's newest action and must survive the teardown.
                self.stopCurrentActivity(discardingPendingStretch: false)
            }
        } else {
            stopCurrentActivity()
            activeChannelID = nil
            listenState = .idle
            tourCode = nil
            connectionState = .idle
            guestCredential = nil
        }
        Logger.channel.info("Left channel")
    }

    /// Process-termination path (FND-8): the synchronous, bounded leave flush is the only place the
    /// main thread may wait, because the process has seconds left and no Task will run.
    func terminate() {
        sessionAttempt &+= 1
        guard let ch = activeChannel else { return }
        let isGuide = ch.createdBy == coordinator.controlPlane.localPeer.id
        sessionGeneration &+= 1
        if isGuide {
            audioEngine.stopCapture()
            captureTask?.cancel()
            captureTask = nil
            do {
                try tourControlService.endGuideSessionBeforeTermination()
            } catch {
                Logger.channel.error("Failed to send authenticated session end at termination (\(String(describing: type(of: error))))")
            }
            stopCurrentActivity()
            channels.removeAll { $0.id == ch.id }
            coordinator.controlPlane.broadcast(.channelEnded(channelID: ch.id))
        } else {
            stopCurrentActivity()
        }
        activeChannelID = nil
        listenState = .idle
        tourCode = nil
        connectionState = .idle
        guestCredential = nil
        Logger.channel.info("Terminated session")
    }

    // MARK: - Private

    /// PBKDF2 stretch of the tour code (ADR-042) runs off the main actor; the core API stays synchronous.
    @concurrent
    private static func stretchCredential(shortCode: String, sessionID: UUID) async throws -> SessionCredential {
        try SessionCredential.derive(shortCode: shortCode, sessionID: sessionID)
    }

    private func startCapturing(plane: any AudioPlane, channelID: String) throws {
        let stream = try audioEngine.startCapture()
        captureTask = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { break }
                plane.sendAudio(data)
            }
            // The stream ends on its own only when the engine tore the pipeline down (interruption
            // or route rebuild failure): keep control/asset lanes up and let the guide decide (DSCN-12).
            guard let self, !Task.isCancelled, self.listenState == .broadcasting else { return }
            self.tourFeatureError = "Microphone capture stopped"
            Logger.channel.error("Capture stream ended while broadcasting")
        }
    }

    /// Every lane is cleared and the Bonjour record is withdrawn (FND-2); `unpublishChannel` is a
    /// no-op when nothing was published, so this is safe now that publish is the last startup step.
    private func rollbackFailedGuideSession(channelID: String) {
        audioEngine.stopCapture()
        captureTask?.cancel()
        captureTask = nil
        coordinator.activeAudioPlane?.setSessionEventHandler(nil)
        coordinator.activeAudioPlane?.clearSession()
        tourControlService.clearSession()
        assetTransferService.clearSession()
        localGuidanceService.stop()
        channels.removeAll { $0.id == channelID }
        activeChannelID = nil
        listenState = .idle
        connectionState = .failed
        guestCredential = nil
        participantRegistry = ParticipantRegistry()
        listenerCount = 0
        coordinator.controlPlane.broadcast(.channelEnded(channelID: channelID))
    }

    /// `discardingPendingStretch` is false only from the deferred End Tour teardown: that leave
    /// already bumped `sessionAttempt`, and a create/join started inside the flush window must
    /// survive it (ADR-048).
    private func stopCurrentActivity(discardingPendingStretch: Bool = true) {
        if discardingPendingStretch { sessionAttempt &+= 1 }
        sessionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        pendingAudioLaneFailure = nil
        consecutiveAudioLaneFailures = 0
        guestCredential = nil
        if listenState == .broadcasting {
            audioEngine.stopCapture()
            captureTask?.cancel()
            captureTask = nil
        } else if listenState == .listening {
            audioEngine.stopPlayback()
        }
        coordinator.activeAudioPlane?.setSessionEventHandler(nil)
        coordinator.activeAudioPlane?.clearSession()
        tourControlService.clearSession()
        assetTransferService.clearSession()
        localGuidanceService.stop()
        offlineMapConfiguration = nil
        offlineMapStatus = .unavailable
        participantRegistry = ParticipantRegistry()
        listenerCount = 0
        connectionState = .idle
    }

    private func refreshOfflineMap() {
        let manifest = isCreator ? try? contentStore.manifestPayload() : assetTransferService.manifest
        guard let manifest else {
            offlineMapConfiguration = nil
            offlineMapStatus = listenState == .listening ? .transferring : .unavailable
            return
        }
        let hasStyle = manifest.assets.contains { $0.kind == .mapStyle }
        let hasArchive = manifest.assets.contains { $0.kind == .mapArchive }
        guard hasStyle || hasArchive else {
            offlineMapConfiguration = nil
            offlineMapStatus = .unavailable
            return
        }
        guard hasStyle, hasArchive else {
            let message = "The tour pack contains an incomplete offline map"
            offlineMapConfiguration = nil
            offlineMapStatus = .failed(message)
            tourFeatureError = message
            return
        }
        let files = isCreator ? contentStore.sourcesByAssetID : assetTransferService.readyURLsByAssetID
        do {
            offlineMapConfiguration = try OfflineMapPack.resolve(
                manifest: manifest,
                filesByAssetID: files
            )
            offlineMapStatus = .ready
        } catch OfflineMapPackError.styleNotReady, OfflineMapPackError.archiveNotReady {
            offlineMapConfiguration = nil
            offlineMapStatus = .transferring
        } catch {
            offlineMapConfiguration = nil
            offlineMapStatus = .failed(error.localizedDescription)
            tourFeatureError = error.localizedDescription
        }
    }

    private func publishCurrentTourPack() async throws {
        let manifest = try contentStore.manifestPayload()
        try await assetTransferService.hostTourPack(
            manifest,
            sourcesByAssetID: contentStore.sourcesByAssetID
        )
        try tourControlService.updateDeck(deckID: manifest.packID, slides: manifest.assets)
    }

    private func broadcastChannelAnnounce(_ channel: Channel) {
        guard channel.createdBy == coordinator.controlPlane.localPeer.id else { return }
        let announce = BLECommand.ChannelAnnounce(
            channelID: channel.id,
            channelName: channel.name,
            createdBy: channel.createdBy,
            audioQuality: audioQuality,
            wifiSSID: nil,
            audioHostIP: channel.audioHostIP
        )
        coordinator.controlPlane.broadcast(.channelAnnounce(announce: announce))
    }

    private func broadcastAllChannels() {
        for channel in channels {
            broadcastChannelAnnounce(channel)
        }
    }

    // MARK: - Periodic Broadcast

    private func startPeriodicBroadcast() {
        listenTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.channels.isEmpty else { continue }
                self.broadcastAllChannels()
            }
        })
    }

    // MARK: - Command Listeners

    private func listenForChannelCommands() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (command, _) in self.coordinator.channelCommands {
                switch command {
                case .channelAnnounce(announce: let announce):
                    if let idx = self.channels.firstIndex(where: { $0.id == announce.channelID }) {
                        let previousHostIP = self.channels[idx].audioHostIP
                        self.channels[idx].name = announce.channelName
                        self.channels[idx].audioHostIP = announce.audioHostIP
                        Logger.channel.info("Updated discovered megaphone")

                        if self.activeChannelID == announce.channelID,
                           self.listenState == .listening,
                           previousHostIP != announce.audioHostIP,
                           let updatedChannel = self.channels[safe: idx] {
                            // Discovery may only reconfigure the existing credential (FND-6, ADR-036).
                            self.restartGuestTransports(channel: updatedChannel, connectionState: .connecting)
                        }
                    } else {
                        let channel = Channel(
                            id: announce.channelID,
                            name: announce.channelName,
                            createdAt: Date(),
                            createdBy: announce.createdBy,
                            audioHostIP: announce.audioHostIP
                        )
                        self.channels.append(channel)
                        Logger.channel.info("Discovered megaphone")
                    }
                case .channelUnavailable(let channelID), .channelEnded(let channelID):
                    self.handleDiscoveryUnavailable(channelID: channelID)

                default:
                    break
                }
            }
        })
    }

    private func listenForPeerEvents() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.coordinator.channelPeerEvents {
                if case .connected = event {
                    self.broadcastAllChannels()
                }
            }
        })
    }

    /// Single source of the user-facing version-mismatch text for every guest and guide path.
    nonisolated static func versionMismatchMessage(remoteMajor: UInt8, localMajor: UInt8) -> String {
        "Tour protocol version mismatch (remote \(remoteMajor), local \(localMajor)). Update the older app."
    }

    private func handleAudioSessionEvent(_ event: AudioSessionEvent) {
        switch event {
        case let .joined(participant):
            participantRegistry.register(participant)
            listenerCount = participantRegistry.listenerCount
            Logger.channel.info("Session guest joined; listeners=\(self.listenerCount)")
        case let .disconnected(connectionID):
            participantRegistry.disconnect(connectionID: connectionID)
            listenerCount = participantRegistry.listenerCount
            Logger.channel.info("Session connection left; listeners=\(self.listenerCount)")
        case let .versionMismatch(remoteMajor, localMajor):
            // DSCN-13: one legacy guest must not end the guide's tour. The transport already closed
            // that connection; the guide only sees the reason.
            tourFeatureError = Self.versionMismatchMessage(remoteMajor: remoteMajor, localMajor: localMajor)
            Logger.channel.error("Rejected a legacy guest on the audio lane")
        case let .failed(message):
            connectionState = .failed
            tourFeatureError = message
        }
    }

    private func startGuestTransports(
        channel: Channel,
        hostIP: String,
        sessionID: UUID,
        participantID: UUID,
        credential: SessionCredential
    ) {
        tourControlService.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: coordinator.controlPlane.localPeer.displayName,
            platform: .iOS,
            credential: credential
        )
        assetTransferService.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: coordinator.controlPlane.localPeer.displayName,
            platform: .iOS,
            credential: credential
        )
        tourControlService.startGuest(hostIP: hostIP)
        assetTransferService.joinTour(hostIP: hostIP)

        let plane = coordinator.selectAudioPlane()
        plane.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: coordinator.controlPlane.localPeer.displayName,
            platform: .iOS,
            credential: credential
        )
        plane.setSessionEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handleGuestAudioSessionEvent(event) }
        }
        if let tcpPlane = plane as? UDPAudioPlane {
            tcpPlane.hostIP = hostIP
        }
        pendingAudioLaneFailure = nil
        audioEngine.startPlayback()
        // The first delivered PCM buffer of this run proves the audio lane works again (DSCN-19).
        let awaitingFirstBuffer = OSAllocatedUnfairLock(initialState: true)
        plane.startListening(channelID: channel.id) { [weak self] data in
            let isFirstBuffer = awaitingFirstBuffer.withLock { flag in
                defer { flag = false }
                return flag
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isFirstBuffer { self.consecutiveAudioLaneFailures = 0 }
                self.audioEngine.enqueuePlayback(data)
            }
        }
    }

    /// Guest-side audio-lane events. Loss is a reconnect trigger with the same authority as
    /// control-lane loss (ADR-044); `handleAudioSessionEvent` stays guide-only.
    private func handleGuestAudioSessionEvent(_ event: AudioSessionEvent) {
        guard listenState == .listening else { return }
        switch event {
        case .joined, .disconnected:
            break // Guide-side membership events; never emitted to a guest.
        case let .versionMismatch(remoteMajor, localMajor):
            handleControlConnectionEvent(.versionMismatch(remoteMajor: remoteMajor, localMajor: localMajor))
        case let .failed(message):
            consecutiveAudioLaneFailures += 1
            guard consecutiveAudioLaneFailures < 5 else {
                failGuestSession(message: "Audio connection lost repeatedly")
                return
            }
            switch connectionState {
            case .connected:
                handleControlConnectionEvent(.failed(message))
            case .connecting, .reconnecting:
                // The control handshake of this run is still in flight (initial join or a reconnect
                // cycle); `.connected` would otherwise cancel the reconnect and leave a mute
                // CONNECTED guest. Consumed in handleControlConnectionEvent, cleared per run.
                pendingAudioLaneFailure = message
            case .idle, .failed:
                break // The session is not running or is terminal.
            }
        }
    }

    /// Terminal guest failure: the failed channel stays on screen with its reason.
    private func failGuestSession(message: String) {
        reconnectTask?.cancel()
        reconnectTask = nil
        stopCurrentActivity()
        connectionState = .failed
        tourFeatureError = message
    }

    private func handleControlConnectionEvent(_ event: TourControlConnectionEvent) {
        guard listenState == .listening else { return }
        switch event {
        case .connected:
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            connectionState = .connected
            tourFeatureError = nil
            if let pending = pendingAudioLaneFailure {
                pendingAudioLaneFailure = nil
                scheduleReconnect(reason: pending)
            }
        case .disconnected:
            scheduleReconnect(reason: "Guide connection closed")
        case .sessionEnded:
            endGuestSessionFromGuide()
        case let .versionMismatch(remoteMajor, localMajor):
            failGuestSession(message: Self.versionMismatchMessage(remoteMajor: remoteMajor, localMajor: localMajor))
        case .credentialRejected:
            // A wrong code cannot succeed on retry (FND-8): terminal, credentials erased.
            Logger.channel.error("The guide rejected the tour code; not retrying")
            failGuestSession(message: "The tour code was rejected. Check it with the guide.")
        case let .failed(message):
            scheduleReconnect(reason: message)
        }
    }

    private func scheduleReconnect(reason: String) {
        pendingAudioLaneFailure = nil
        guard reconnectTask == nil,
              reconnectAttempt < 5,
              let channel = activeChannel,
              guestCredential != nil,
              channel.audioHostIP != nil else {
            if reconnectAttempt >= 5 {
                failGuestSession(message: "Could not reconnect to the guide")
            }
            return
        }
        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        Logger.channel.error("Session reconnect attempt \(self.reconnectAttempt)")
        let delay = reconnectBaseDelay * (1 << (reconnectAttempt - 1))
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.listenState == .listening else { return }
            self.reconnectTask = nil
            // A fresher discovery address wins over the one captured when the reconnect was scheduled.
            self.restartGuestTransports(channel: self.activeChannel ?? channel)
        }
    }

    /// Stop + reconfigure of the guest lanes with the retained credential (FND-6, DSCN-11). Used by
    /// the discovery address change and by the reconnect timer. Never `joinChannel`, never
    /// `clearSession`, never a fresh credential stretch.
    private func restartGuestTransports(channel: Channel, connectionState newState: ConnectionState? = nil) {
        guard listenState == .listening else { return }
        guard let credential = guestCredential else {
            Logger.channel.error("Cannot restart guest transports without an admitted credential")
            return
        }
        guard let hostIP = channel.audioHostIP,
              let sessionID = UUID(uuidString: channel.id),
              let participantID = UUID(uuidString: coordinator.controlPlane.localPeer.id) else {
            Logger.channel.error("Cannot restart guest transports without a guide address and UUID identities")
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        coordinator.activeAudioPlane?.stop()
        tourControlService.stop()
        assetTransferService.stop()
        audioEngine.stopPlayback()
        pendingAudioLaneFailure = nil
        if let newState {
            connectionState = newState
        }
        startGuestTransports(
            channel: channel,
            hostIP: hostIP,
            sessionID: sessionID,
            participantID: participantID,
            credential: credential
        )
    }

    private func handleDiscoveryUnavailable(channelID: String) {
        guard activeChannelID != channelID else {
            Logger.channel.info("Active channel discovery became unavailable; data session remains authoritative")
            return
        }
        channels.removeAll { $0.id == channelID }
    }

    private func endGuestSessionFromGuide() {
        guard let channelID = activeChannelID else { return }
        stopCurrentActivity()
        channels.removeAll { $0.id == channelID }
        activeChannelID = nil
        listenState = .idle
        tourCode = nil
        connectionState = .idle
        guestCredential = nil
        Logger.channel.info("Authenticated guide ended the session")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
