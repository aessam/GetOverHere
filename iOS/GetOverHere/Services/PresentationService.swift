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
    /// Island guests' advisory reports carried by a bridge (ADR-081 W5, DSCN-3), keyed by far guest.
    @ObservationIgnored private var islandAudioReports: [UUID: (bridge: UUID, report: AudioReadinessPayload)] = [:]
    @ObservationIgnored private var relayUpstreamOpener: SessionFrameOpener?
    @ObservationIgnored private var localAudioReport = AudioReadinessPayload(status: .waiting, revision: 0)
    @ObservationIgnored private var guestControlConnected = false

    @ObservationIgnored private let transport: SessionControlTransport
    @ObservationIgnored private var connectedGuestIDs: Set<UUID> = []
    @ObservationIgnored private var role: PresentationServiceRole?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var connectionEventHandler: (@MainActor @Sendable (TourControlConnectionEvent) -> Void)?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var currentSlideHandler: (@MainActor (String?) -> Void)?
    /// ADR-081 P2: guide side chooses the single bridge; guest side keeps the newest guide-signed assignment.
    private(set) var bridgeAssignment: BridgeAssignmentPayload?
    @ObservationIgnored private var bridgeAuthority: BridgeAuthority?
    @ObservationIgnored private var bridgeCandidates: [UUID: BridgeCandidate] = [:]
    @ObservationIgnored private var joinCounter: UInt64 = 0
    @ObservationIgnored private var bridgeLeaseTask: Task<Void, Never>?

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
        relayUpstreamOpener = SessionFrameOpener(credential: credential)
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
        bridgeAuthority = BridgeAuthority(guidePlatform: .iOS)
        bridgeCandidates = [:]
        bridgeAssignment = nil
        try transport.startGuide()
        let generation = sessionGeneration
        bridgeLeaseTask?.cancel()
        bridgeLeaseTask = Task { @MainActor [weak self] in
            // Renews the bridge lease well before it lapses (BridgeAuthority renews at half the lease).
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.sessionGeneration == generation, self.role == .guide else { return }
                self.planBridge()
            }
        }
    }

    static let maximumIslandReports = 8

    private func recountAudioReady() {
        let bridge = bridgeAssignment?.bridgeID
        audioReadyGuestCount = guestAudioReports.values.filter { $0.status == .playing }.count +
            islandAudioReports.values.filter { $0.bridge == bridge && $0.report.status == .playing }.count
    }

    /// W5: an island guest's sealed audio status or leave, carried by the current bridge (ADR-081, DSCN-3).
    private func acceptRelayUpstream(_ payload: Data, bridge: UUID) throws {
        let record = try RelayUpstreamRecord.decode(payload)
        guard record.lane == .control, let opener = relayUpstreamOpener else { return }
        guard case let .opened(inner) = try opener.open(SealedSessionEnvelope.decode(record.frame)),
              inner.sessionID == sessionID, inner.senderID == record.farParticipantID, inner.senderID != bridge,
              !connectedGuestIDs.contains(inner.senderID) else { return }
        switch inner.kind {
        case .audioStatus:
            let report = try AudioReadinessPayload.decode(inner.payload)
            if let previous = islandAudioReports[inner.senderID], previous.bridge == bridge,
               report.revision <= previous.report.revision { return }
            // Reports from an earlier bridge are dropped; one island holds at most the star cap (CrossIslandDesign).
            islandAudioReports = islandAudioReports.filter { $0.value.bridge == bridge }
            guard islandAudioReports[inner.senderID] != nil || islandAudioReports.count < Self.maximumIslandReports else { return }
            islandAudioReports[inner.senderID] = (bridge, report)
        case .leave:
            islandAudioReports.removeValue(forKey: inner.senderID)
        default:
            return
        }
        recountAudioReady()
    }

    /// Sends the guide-signed `bridgeAssignment` when the bridge, its standbys or its lease change (ADR-081 D2).
    private func planBridge() {
        guard role == .guide, var authority = bridgeAuthority else { return }
        do {
            let next = try authority.plan(candidates: Array(bridgeCandidates.values),
                                          nowMilliseconds: Self.nowMilliseconds())
            bridgeAuthority = authority
            bridgeAssignment = authority.current
            recountAudioReady() // island reports count only while their bridge holds the assignment
            if let next { transport.send(kind: .bridgeAssignment, payload: next.encode()) }
        } catch {
            report(error)
        }
    }

    /// Guest: raw GOS1 bytes of each opened guide control frame (ADR-081 bridge upstream); read at the next start.
    func setUpstreamFrameTap(_ tap: UpstreamFrameTap?) { transport.setUpstreamFrameTap(tap) }

    /// Bridge: carry an island guest's advisory frame to the guide (W5).
    func sendRelayUpstream(_ record: RelayUpstreamRecord) {
        transport.send(kind: .relayUpstream, payload: record.encode())
    }

    /// Experimental (ADR-081): advertise this guest as able to bridge its platform island; read at the next hello.
    func setRelayHostCapable(_ capable: Bool) {
        transport.helloCapabilities = capable ? SessionCapabilities.relayHost.rawValue : 0
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
        islandAudioReports.removeAll()
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
        bridgeLeaseTask?.cancel()
        bridgeLeaseTask = nil
        bridgeAuthority = nil
        bridgeCandidates = [:]
        bridgeAssignment = nil
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
            recountAudioReady()
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
            joinCounter &+= 1
            bridgeCandidates[participant.participantID] = BridgeCandidate(participantID: participant.participantID,
                platform: participant.platform, capabilities: participant.capabilities, joinOrder: joinCounter)
            let before = bridgeAssignment
            planBridge()
            // A joiner also needs the assignment that was already in force (planBridge sends only changes).
            if let current = bridgeAssignment, current == before { transport.send(kind: .bridgeAssignment, payload: current.encode()) }
        case let .envelopeReceived(envelope):
            guard envelope.sessionID == sessionID else { return }
            if role == .guide, envelope.kind == .relayUpstream {
                // Only the assigned bridge carries island frames; they are advisory counts, never authority.
                guard let bridge = bridgeAssignment?.bridgeID, envelope.senderID == bridge,
                      connectedGuestIDs.contains(bridge) else { return }
                do { try acceptRelayUpstream(envelope.payload, bridge: bridge) } catch { self.report(error) }
                return
            }
            if role == .guide, envelope.kind == .audioStatus {
                guard connectedGuestIDs.contains(envelope.senderID) else { return }
                do {
                    let report = try AudioReadinessPayload.decode(envelope.payload)
                    if let previous = guestAudioReports[envelope.senderID], report.revision <= previous.revision { return }
                    guestAudioReports[envelope.senderID] = report
                    recountAudioReady()
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
                case .bridgeAssignment:
                    // Kept for relay failover (P3); an older generation never replaces a newer one.
                    let incoming = try BridgeAssignmentPayload.decode(envelope.payload)
                    guard bridgeAssignment.map({ incoming.generation >= $0.generation }) ?? true else { return }
                    bridgeAssignment = incoming
                default:
                    throw PresentationServiceError.unexpectedMessage(envelope.kind)
                }
            } catch {
                report(error)
            }
        case let .guestDisconnected(participantID):
            if bridgeCandidates.removeValue(forKey: participantID) != nil { planBridge() }
            connectedGuestIDs.remove(participantID)
            guestAudioReports.removeValue(forKey: participantID)
            recountAudioReady()
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
