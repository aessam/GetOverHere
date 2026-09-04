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
    private let audioEngine: AudioEngine
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

    // MARK: - Init

    init(
        coordinator: NetworkCoordinator,
        audioEngine: AudioEngine,
        tourControlService: TourControlService,
        assetTransferService: TourAssetTransferService,
        contentStore: TourContentStore,
        localGuidanceService: LocalGuidanceService
    ) {
        self.coordinator = coordinator
        self.audioEngine = audioEngine
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
                guard attempt == sessionAttempt else { return }
                tourCode = nil
                tourFeatureError = error.localizedDescription
                Logger.channel.error("Cannot derive the tour credential")
                return
            }
            guard attempt == sessionAttempt else { return }
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
            tourControlService.startGuide(deckID: sessionID)
            try assetTransferService.startGuideWithEmptyTourPack(emptyManifest)
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
            plane.startBroadcasting(channelID: channel.id, quality: audioQuality)
            try startCapturing(plane: plane, channelID: channel.id)
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
                guard attempt == sessionAttempt else { return }
                tourFeatureError = error.localizedDescription
                return
            }
            guard attempt == sessionAttempt else { return }
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
        if isGuide {
            do {
                try tourControlService.endGuideSession()
            } catch {
                Logger.channel.error("Failed to send authenticated session end")
            }
        }
        stopCurrentActivity()
        activeChannelID = nil
        listenState = .idle
        tourCode = nil
        connectionState = .idle
        guestCredential = nil
        Logger.channel.info("Left channel")

        if isGuide {
            channels.removeAll { $0.id == ch.id }
            coordinator.controlPlane.broadcast(.channelEnded(channelID: ch.id))
        }
    }

    // MARK: - Private

    /// PBKDF2 stretch of the tour code (ADR-042) runs off the main actor; the core API stays synchronous.
    @concurrent
    private static func stretchCredential(shortCode: String, sessionID: UUID) async throws -> SessionCredential {
        try SessionCredential.derive(shortCode: shortCode, sessionID: sessionID)
    }

    private func startCapturing(plane: any AudioPlane, channelID: String) throws {
        let stream = try audioEngine.startCapture()
        captureTask = Task {
            for await data in stream {
                guard !Task.isCancelled else { break }
                plane.sendAudio(data)
            }
        }
    }

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
    }

    private func stopCurrentActivity() {
        sessionAttempt &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
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
                            if let tourCode = self.tourCode {
                                self.joinChannel(updatedChannel, tourCode: tourCode)
                            }
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
            connectionState = .failed
            tourFeatureError = Self.versionMismatchMessage(remoteMajor: remoteMajor, localMajor: localMajor)
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
        plane.setSessionEventHandler(nil)
        if let tcpPlane = plane as? UDPAudioPlane {
            tcpPlane.hostIP = hostIP
        }
        audioEngine.startPlayback()
        plane.startListening(channelID: channel.id) { [weak self] data in
            Task { @MainActor [weak self] in self?.audioEngine.enqueuePlayback(data) }
        }
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
        case .disconnected:
            scheduleReconnect(reason: "Guide connection closed")
        case .sessionEnded:
            endGuestSessionFromGuide()
        case let .versionMismatch(remoteMajor, localMajor):
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionState = .failed
            tourFeatureError = Self.versionMismatchMessage(remoteMajor: remoteMajor, localMajor: localMajor)
        case let .failed(message):
            scheduleReconnect(reason: message)
        }
    }

    private func scheduleReconnect(reason: String) {
        guard reconnectTask == nil,
              reconnectAttempt < 5,
              let channel = activeChannel,
              let credential = guestCredential,
              let hostIP = channel.audioHostIP,
              let sessionID = UUID(uuidString: channel.id),
              let participantID = UUID(uuidString: coordinator.controlPlane.localPeer.id) else {
            if reconnectAttempt >= 5 {
                connectionState = .failed
                tourFeatureError = "Could not reconnect to the guide"
            }
            return
        }
        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        Logger.channel.error("Session reconnect attempt \(self.reconnectAttempt)")
        let delaySeconds = 1 << (reconnectAttempt - 1)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }
            guard let self, self.listenState == .listening else { return }
            self.reconnectTask = nil
            self.coordinator.activeAudioPlane?.stop()
            self.tourControlService.stop()
            self.assetTransferService.stop()
            self.audioEngine.stopPlayback()
            self.startGuestTransports(
                channel: channel,
                hostIP: hostIP,
                sessionID: sessionID,
                participantID: participantID,
                credential: credential
            )
        }
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
