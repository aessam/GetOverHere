import Foundation
import Observation
import TourSessionCore

enum PresentationServiceRole {
    case guide
    case guest
}

enum TourControlConnectionEvent: Sendable {
    case connected
    case disconnected
    case sessionEnded
    case versionMismatch(remoteMajor: UInt8, localMajor: UInt8)
    /// The guide rejected the tour code; terminal, never retried (FND-8).
    case credentialRejected(String)
    case failed(String)
}

enum PresentationServiceError: LocalizedError {
    case guideOnly
    case unknownSlide(String)
    case invalidBearing
    case unexpectedMessage(SessionMessageKind)

    var errorDescription: String? {
        switch self {
        case .guideOnly:
            "Only the guide can change the presentation"
        case let .unknownSlide(assetID):
            "Unknown slide asset ID \(assetID)"
        case .invalidBearing:
            "A valid compass heading is required"
        case let .unexpectedMessage(kind):
            "Unexpected control-channel message \(kind)"
        }
    }
}

@Observable
@MainActor
final class TourControlService {
    private(set) var snapshot: PresentationSnapshotPayload?
    private(set) var targetSnapshot: TargetSnapshotPayload?
    private(set) var bearingSnapshot: BearingSnapshotPayload?
    private(set) var visualFocusSnapshot: VisualFocusSnapshotPayload?
    private(set) var slides: [TourAssetDescriptor] = []
    private(set) var lastError: String?
    /// Guests admitted on the control lane, keyed by participant (FND-13); independent of audio readiness.
    private(set) var connectedGuestCount = 0
    private(set) var audioReadyGuestCount = 0
    @ObservationIgnored private var guestAudioReports: [UUID: AudioReadinessPayload] = [:]
    @ObservationIgnored private var localAudioReport = AudioReadinessPayload(status: .waiting, revision: 0)
    @ObservationIgnored private var guestControlConnected = false

    @ObservationIgnored private let transport: SessionControlTransport
    @ObservationIgnored private var connectedGuestIDs: Set<UUID> = []
    @ObservationIgnored private var role: PresentationServiceRole?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var connectionEventHandler: (@MainActor @Sendable (TourControlConnectionEvent) -> Void)?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var currentSlideHandler: (@MainActor (String?) -> Void)?

    var currentSlideID: String? { snapshot?.currentSlideID }
    var isVisible: Bool { snapshot?.isVisible == true }

    var currentSlideIndex: Int? {
        guard let currentSlideID else { return nil }
        return slides.firstIndex { $0.assetID == currentSlideID }
    }

    var canGoPrevious: Bool {
        guard let currentSlideIndex else { return false }
        return currentSlideIndex > slides.startIndex
    }

    var canGoNext: Bool {
        guard let currentSlideIndex else { return false }
        return currentSlideIndex < slides.index(before: slides.endIndex)
    }

    init(transport: SessionControlTransport? = nil) {
        let resolvedTransport = transport ?? LocalSessionControlTransport()
        self.transport = resolvedTransport
        installTransportHandler()
    }

    private func installTransportHandler() {
        let generation = sessionGeneration
        transport.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.handle(event)
            }
        }
    }

    func setConnectionEventHandler(
        _ handler: (@MainActor @Sendable (TourControlConnectionEvent) -> Void)?
    ) {
        connectionEventHandler = handler
    }

    func setCurrentSlideHandler(_ handler: (@MainActor (String?) -> Void)?) {
        currentSlideHandler = handler
        handler?(currentSlideID)
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        stop()
        self.sessionID = sessionID
        transport.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func configureGuideAuthentication(_ authentication: SessionGuideAuthentication) {
        transport.configureGuideAuthentication(authentication)
    }

    func reportAudioReadiness(_ status: AudioReadinessStatus) {
        guard role == .guest, localAudioReport.status != status else { return }
        guard localAudioReport.revision < .max else {
            report("Audio readiness revision exhausted. Leave and rejoin the room.")
            return
        }
        localAudioReport = AudioReadinessPayload(status: status, revision: localAudioReport.revision + 1)
        sendAudioReadiness()
    }

    private func sendAudioReadiness() {
        guard role == .guest, guestControlConnected else { return }
        transport.send(kind: .audioStatus, payload: localAudioReport.encode())
    }

    /// Synchronous and throwing (FND-2): a lane that cannot listen fails the guide's startup here.
    func startGuide(deckID: UUID, slides: [TourAssetDescriptor] = []) throws {
        sessionGeneration &+= 1
        installTransportHandler()
        role = .guide
        self.slides = Self.orderedSlides(slides)
        snapshot = PresentationSnapshotPayload(
            stateVersion: 0,
            deckID: deckID,
            currentSlideID: self.slides.first?.assetID,
            isVisible: false,
            effectiveAtMilliseconds: Self.nowMilliseconds()
        )
        visualFocusSnapshot = VisualFocusSnapshotPayload(stateVersion: 0, mode: .slides)
        currentSlideHandler?(currentSlideID)
        try transport.startGuide()
    }

    func startGuest(hostIP: String) {
        sessionGeneration &+= 1
        installTransportHandler()
        role = .guest
        transport.hostIP = hostIP
        transport.startGuest()
    }

    /// Flushes the authenticated leave without blocking the main actor (FND-8).
    func endGuideSession() async throws {
        try requireGuide()
        await transport.sendLeave()
    }

    /// Process-termination variant: the synchronous, bounded flush is the only allowed main-thread
    /// wait because no Task will run before the process exits.
    func endGuideSessionBeforeTermination() throws {
        try requireGuide()
        transport.send(kind: .leave, payload: Data())
    }

    func updateDeck(deckID: UUID, slides: [TourAssetDescriptor]) throws {
        try requireGuide()
        let ordered = Self.orderedSlides(slides)
        let currentID = snapshot?.currentSlideID
        self.slides = ordered
        let selectedID = currentID.flatMap { id in
            ordered.contains(where: { $0.assetID == id }) ? id : nil
        } ?? ordered.first?.assetID
        try publish(deckID: deckID, slideID: selectedID, isVisible: snapshot?.isVisible == true && selectedID != nil)
    }

    func acceptTourPack(_ manifest: TourPackManifestPayload) {
        guard role == .guest else { return }
        slides = Self.orderedSlides(manifest.assets)
        currentSlideHandler?(currentSlideID)
    }

    func showSlide(assetID: String? = nil) throws {
        try requireGuide()
        guard let deckID = snapshot?.deckID ?? sessionID else { return }
        let selectedID = assetID ?? snapshot?.currentSlideID ?? slides.first?.assetID
        if let selectedID, !slides.contains(where: { $0.assetID == selectedID }) {
            throw PresentationServiceError.unknownSlide(selectedID)
        }
        try publish(deckID: deckID, slideID: selectedID, isVisible: selectedID != nil)
        try ensureVisualFocus(.slides)
    }

    func hide() throws {
        try requireGuide()
        guard let current = snapshot else { return }
        try publish(deckID: current.deckID, slideID: current.currentSlideID, isVisible: false)
    }

    func goPrevious() throws {
        try move(by: -1)
    }

    func goNext() throws {
        try move(by: 1)
    }

    func setTarget(latitude: Double, longitude: Double, label: String = "") throws {
        try requireGuide()
        let latitudeE7 = try Self.coordinateE7(latitude, range: TargetSnapshotPayload.latitudeRangeE7)
        let longitudeE7 = try Self.coordinateE7(longitude, range: TargetSnapshotPayload.longitudeRangeE7)
        let next = try TargetSnapshotPayload(
            stateVersion: (targetSnapshot?.stateVersion ?? 0) + 1,
            targetID: targetSnapshot?.targetID ?? UUID(),
            latitudeE7: latitudeE7,
            longitudeE7: longitudeE7,
            label: String(label.prefix(256)),
            isVisible: true
        )
        targetSnapshot = next
        transport.send(kind: .targetSnapshot, payload: try next.encode())
        try ensureVisualFocus(.map)
    }

    func clearTarget() throws {
        try requireGuide()
        guard let current = targetSnapshot else { return }
        let next = try TargetSnapshotPayload(
            stateVersion: current.stateVersion + 1,
            targetID: current.targetID,
            latitudeE7: current.latitudeE7,
            longitudeE7: current.longitudeE7,
            label: current.label,
            isVisible: false
        )
        targetSnapshot = next
        transport.send(kind: .targetSnapshot, payload: try next.encode())
    }

    func shareBearing(degrees: Double) throws {
        try requireGuide()
        guard degrees.isFinite, degrees >= 0, degrees < 360 else {
            throw PresentationServiceError.invalidBearing
        }
        let next = try BearingSnapshotPayload(
            stateVersion: (bearingSnapshot?.stateVersion ?? 0) + 1,
            reference: .magnetic,
            bearingMilliDegrees: UInt32((degrees * 1_000).rounded()),
            isVisible: true
        )
        bearingSnapshot = next
        transport.send(kind: .bearingSnapshot, payload: next.encode())
        try ensureVisualFocus(.pointer)
    }

    func setVisualFocus(_ mode: TourVisualMode) throws {
        try requireGuide()
        try publishVisualFocus(mode)
    }

    func clearBearing() throws {
        try requireGuide()
        guard let current = bearingSnapshot else { return }
        let next = try BearingSnapshotPayload(
            stateVersion: current.stateVersion + 1,
            reference: current.reference,
            bearingMilliDegrees: current.bearingMilliDegrees,
            isVisible: false
        )
        bearingSnapshot = next
        transport.send(kind: .bearingSnapshot, payload: next.encode())
    }

    func stop() {
        sessionGeneration &+= 1
        transport.stop()
        guestControlConnected = false
        guestAudioReports.removeAll()
        audioReadyGuestCount = 0
        role = nil
        sessionID = nil
        snapshot = nil
        targetSnapshot = nil
        bearingSnapshot = nil
        visualFocusSnapshot = nil
        slides = []
        currentSlideHandler?(nil)
        lastError = nil
        connectedGuestIDs.removeAll()
        connectedGuestCount = 0
        installTransportHandler()
    }

    func clearSession() {
        stop()
        localAudioReport = AudioReadinessPayload(status: .waiting, revision: 0)
        transport.clearSession()
    }

    private func move(by offset: Int) throws {
        try requireGuide()
        guard !slides.isEmpty else { return }
        let current = currentSlideIndex ?? slides.startIndex
        let destination = min(max(current + offset, slides.startIndex), slides.index(before: slides.endIndex))
        try showSlide(assetID: slides[destination].assetID)
    }

    private func requireGuide() throws {
        guard role == .guide else { throw PresentationServiceError.guideOnly }
    }

    private func publish(deckID: UUID, slideID: String?, isVisible: Bool) throws {
        let nextVersion = (snapshot?.stateVersion ?? 0) + 1
        let next = PresentationSnapshotPayload(
            stateVersion: nextVersion,
            deckID: deckID,
            currentSlideID: slideID,
            isVisible: isVisible,
            effectiveAtMilliseconds: Self.nowMilliseconds()
        )
        snapshot = next
        currentSlideHandler?(currentSlideID)
        transport.send(kind: .presentationSnapshot, payload: try next.encode())
    }

    private func ensureVisualFocus(_ mode: TourVisualMode) throws {
        guard visualFocusSnapshot?.mode != mode else { return }
        try publishVisualFocus(mode)
    }

    private func publishVisualFocus(_ mode: TourVisualMode) throws {
        let next = VisualFocusSnapshotPayload(
            stateVersion: (visualFocusSnapshot?.stateVersion ?? 0) + 1,
            mode: mode
        )
        visualFocusSnapshot = next
        transport.send(kind: .visualFocusSnapshot, payload: next.encode())
    }

    private func handle(_ event: SessionControlEvent) {
        guard role != nil else { return }
        switch event {
        case .connected:
            guestControlConnected = true
            connectionEventHandler?(.connected)
            sendAudioReadiness()
        case .disconnected:
            guestControlConnected = false
            connectionEventHandler?(.disconnected)
        case let .guestJoined(participant):
            guard role == .guide else { return }
            // Set semantics: a re-registering participant arrives as disconnect + join and counts once.
            connectedGuestIDs.insert(participant.participantID)
            guestAudioReports.removeValue(forKey: participant.participantID)
            audioReadyGuestCount = guestAudioReports.values.filter { $0.status == .playing }.count
            connectedGuestCount = connectedGuestIDs.count
            do {
                if let snapshot {
                    transport.send(kind: .presentationSnapshot, payload: try snapshot.encode())
                }
                if let targetSnapshot {
                    transport.send(kind: .targetSnapshot, payload: try targetSnapshot.encode())
                }
                if let bearingSnapshot {
                    transport.send(kind: .bearingSnapshot, payload: bearingSnapshot.encode())
                }
                if let visualFocusSnapshot {
                    transport.send(kind: .visualFocusSnapshot, payload: visualFocusSnapshot.encode())
                }
            } catch {
                report(error)
            }
        case let .envelopeReceived(envelope):
            guard envelope.sessionID == sessionID else { return }
            if role == .guide, envelope.kind == .audioStatus {
                guard connectedGuestIDs.contains(envelope.senderID) else { return }
                do {
                    let report = try AudioReadinessPayload.decode(envelope.payload)
                    if let previous = guestAudioReports[envelope.senderID], report.revision <= previous.revision { return }
                    guestAudioReports[envelope.senderID] = report
                    audioReadyGuestCount = guestAudioReports.values.filter { $0.status == .playing }.count
                } catch { self.report(error) }
                return
            }
            guard role == .guest else { return }
            do {
                switch envelope.kind {
                case .leave:
                    connectionEventHandler?(.sessionEnded)
                case .presentationSnapshot:
                    let incoming = try PresentationSnapshotPayload.decode(envelope.payload)
                    guard snapshot == nil || incoming.stateVersion > snapshot!.stateVersion else { return }
                    snapshot = incoming
                    currentSlideHandler?(currentSlideID)
                case .targetSnapshot:
                    let incoming = try TargetSnapshotPayload.decode(envelope.payload)
                    guard targetSnapshot == nil || incoming.stateVersion > targetSnapshot!.stateVersion else { return }
                    targetSnapshot = incoming
                case .bearingSnapshot:
                    let incoming = try BearingSnapshotPayload.decode(envelope.payload)
                    guard bearingSnapshot == nil || incoming.stateVersion > bearingSnapshot!.stateVersion else { return }
                    bearingSnapshot = incoming
                case .visualFocusSnapshot:
                    let incoming = try VisualFocusSnapshotPayload.decode(envelope.payload)
                    guard visualFocusSnapshot == nil || incoming.stateVersion > visualFocusSnapshot!.stateVersion else {
                        return
                    }
                    visualFocusSnapshot = incoming
                default:
                    throw PresentationServiceError.unexpectedMessage(envelope.kind)
                }
            } catch {
                report(error)
            }
        case let .guestDisconnected(participantID):
            connectedGuestIDs.remove(participantID)
            guestAudioReports.removeValue(forKey: participantID)
            audioReadyGuestCount = guestAudioReports.values.filter { $0.status == .playing }.count
            connectedGuestCount = connectedGuestIDs.count
        case let .versionMismatch(remoteMajor, localMajor):
            let message = Self.versionMismatchMessage(remoteMajor: remoteMajor, localMajor: localMajor)
            report(message)
            connectionEventHandler?(.versionMismatch(remoteMajor: remoteMajor, localMajor: localMajor))
        case let .credentialRejected(message):
            report(message)
            connectionEventHandler?(.credentialRejected(message))
        case let .failed(message):
            report(message)
            connectionEventHandler?(.failed(message))
        }
    }

    private func report(_ error: Error) {
        report(error.localizedDescription)
    }

    private func report(_ message: String) {
        lastError = message
    }

    private static func orderedSlides(_ assets: [TourAssetDescriptor]) -> [TourAssetDescriptor] {
        assets.filter { $0.kind == .slide }.sorted {
            ($0.order, $0.assetID) < ($1.order, $1.assetID)
        }
    }

    private static func versionMismatchMessage(remoteMajor: UInt8, localMajor: UInt8) -> String {
        "Tour protocol version mismatch (remote \(remoteMajor), local \(localMajor)). Update the older app."
    }

    private static func nowMilliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func coordinateE7(_ coordinate: Double, range: ClosedRange<Int32>) throws -> Int32 {
        let scaled = coordinate * 10_000_000
        guard scaled.isFinite, scaled >= Double(range.lowerBound), scaled <= Double(range.upperBound) else {
            let rejectedValue: Int32 = if !scaled.isFinite {
                0
            } else if scaled < Double(range.lowerBound) {
                range.lowerBound
            } else {
                range.upperBound
            }
            if range == TargetSnapshotPayload.latitudeRangeE7 {
                throw SessionProtocolError.invalidLatitudeE7(rejectedValue)
            }
            throw SessionProtocolError.invalidLongitudeE7(rejectedValue)
        }
        return Int32(scaled.rounded())
    }
}
