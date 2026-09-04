import Foundation
import TourSessionCore

@MainActor
final class HybridSessionRouteController {
    private var lease = SessionRouteLease()

    var selectedRoute: SessionTransportRoute? {
        lease.selectedRoute
    }

    @discardableResult
    func select(_ route: SessionTransportRoute) -> Bool {
        lease.select(route)
    }

    func replace(with route: SessionTransportRoute) {
        lease.reset()
        precondition(lease.select(route))
    }

    func reset() {
        lease.reset()
    }
}

@MainActor
final class HybridAudioPlane: AudioPlane {
    private enum Role {
        case guide
        case guest
    }

    private let local: AudioPlane
    private let aware: AudioPlane?
    private let routeController: HybridSessionRouteController
    private let setLocalHostIP: (String?) -> Void
    private var role: Role?
    private var eventHandler: (@Sendable (AudioSessionEvent) -> Void)?

    var isActive: Bool {
        switch role {
        case .guide:
            local.isActive || aware?.isActive == true
        case .guest:
            switch routeController.selectedRoute {
            case .localLAN: local.isActive
            case .wifiAware: aware?.isActive == true
            case nil: false
            }
        case nil:
            false
        }
    }

    init(
        local: AudioPlane,
        aware: AudioPlane?,
        routeController: HybridSessionRouteController,
        setLocalHostIP: @escaping (String?) -> Void
    ) {
        self.local = local
        self.aware = aware
        self.routeController = routeController
        self.setLocalHostIP = setLocalHostIP
        local.setSessionEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, from: .localLAN)
            }
        }
        aware?.setSessionEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, from: .wifiAware)
            }
        }
    }

    func setLocalGuideHost(_ hostIP: String?) {
        setLocalHostIP(hostIP)
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        local.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
        aware?.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setSessionEventHandler(_ handler: (@Sendable (AudioSessionEvent) -> Void)?) {
        eventHandler = handler
    }

    func startBroadcasting(channelID: String, quality: AudioQuality) throws {
        role = .guide
        try local.startBroadcasting(channelID: channelID, quality: quality)
        try aware?.startBroadcasting(channelID: channelID, quality: quality)
    }

    func sendAudio(_ data: Data) {
        switch role {
        case .guide:
            local.sendAudio(data)
            aware?.sendAudio(data)
        case .guest:
            selectedTransport?.sendAudio(data)
        case nil:
            break
        }
    }

    func startListening(
        channelID: String,
        onAudio: @escaping @Sendable (Data) -> Void
    ) {
        role = .guest
        guard let selectedTransport else { return }
        selectedTransport.startListening(channelID: channelID, onAudio: onAudio)
    }

    func stop() {
        local.stop()
        aware?.stop()
        role = nil
    }

    func clearSession() {
        local.clearSession()
        aware?.clearSession()
        role = nil
    }

    private var selectedTransport: AudioPlane? {
        switch routeController.selectedRoute {
        case .localLAN: local
        case .wifiAware: aware
        case nil: nil
        }
    }

    private func handle(_ event: AudioSessionEvent, from route: SessionTransportRoute) {
        switch role {
        case .guide:
            eventHandler?(event)
        case .guest where routeController.selectedRoute == route:
            eventHandler?(event)
        case .guest, nil:
            break
        }
    }
}

@MainActor
final class HybridSessionControlTransport: SessionControlTransport {
    private enum Role {
        case guide
        case guest
    }

    private let local: SessionControlTransport
    private let aware: SessionControlTransport?
    private let routeController: HybridSessionRouteController
    private var role: Role?
    private var handler: (@Sendable (SessionControlEvent) -> Void)?

    var isActive: Bool {
        switch role {
        case .guide:
            local.isActive || aware?.isActive == true
        case .guest:
            selectedTransport?.isActive == true
        case nil:
            false
        }
    }

    var hostIP: String? {
        get { local.hostIP }
        set { local.hostIP = newValue }
    }

    init(
        local: SessionControlTransport,
        aware: SessionControlTransport?,
        routeController: HybridSessionRouteController
    ) {
        self.local = local
        self.aware = aware
        self.routeController = routeController
        local.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, from: .localLAN)
            }
        }
        aware?.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, from: .wifiAware)
            }
        }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        local.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
        aware?.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() throws {
        role = .guide
        try local.startGuide()
        try aware?.startGuide()
    }

    func startGuest() {
        role = .guest
        selectedTransport?.startGuest()
    }

    func send(kind: SessionMessageKind, payload: Data) {
        switch role {
        case .guide:
            local.send(kind: kind, payload: payload)
            aware?.send(kind: kind, payload: payload)
        case .guest:
            selectedTransport?.send(kind: kind, payload: payload)
        case nil:
            break
        }
    }

    func sendLeave() async {
        switch role {
        case .guide:
            await local.sendLeave()
            await aware?.sendLeave()
        case .guest:
            await selectedTransport?.sendLeave()
        case nil:
            break
        }
    }

    func stop() {
        local.stop()
        aware?.stop()
        role = nil
    }

    func clearSession() {
        local.clearSession()
        aware?.clearSession()
        role = nil
    }

    private var selectedTransport: SessionControlTransport? {
        switch routeController.selectedRoute {
        case .localLAN: local
        case .wifiAware: aware
        case nil: nil
        }
    }

    private func handle(_ event: SessionControlEvent, from route: SessionTransportRoute) {
        switch role {
        case .guide:
            handler?(event)
        case .guest where routeController.selectedRoute == route:
            handler?(event)
        case .guest, nil:
            break
        }
    }
}

@MainActor
final class HybridSessionAssetTransport: SessionAssetTransport {
    private enum Role {
        case guide
        case guest
    }

    private let local: SessionAssetTransport
    private let aware: SessionAssetTransport?
    private let routeController: HybridSessionRouteController
    private var role: Role?
    private var handler: (@Sendable (SessionAssetEvent) -> Void)?

    var isActive: Bool {
        switch role {
        case .guide:
            local.isActive || aware?.isActive == true
        case .guest:
            selectedTransport?.isActive == true
        case nil:
            false
        }
    }

    var hostIP: String? {
        get { local.hostIP }
        set { local.hostIP = newValue }
    }

    init(
        local: SessionAssetTransport,
        aware: SessionAssetTransport?,
        routeController: HybridSessionRouteController
    ) {
        self.local = local
        self.aware = aware
        self.routeController = routeController
        local.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, from: .localLAN)
            }
        }
        aware?.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, from: .wifiAware)
            }
        }
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        local.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
        aware?.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() throws {
        role = .guide
        try local.startGuide()
        try aware?.startGuide()
    }

    func startGuest() {
        role = .guest
        selectedTransport?.startGuest()
    }

    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        switch role {
        case .guide:
            local.send(kind: kind, payload: payload, to: participantID)
            aware?.send(kind: kind, payload: payload, to: participantID)
        case .guest:
            selectedTransport?.send(kind: kind, payload: payload, to: participantID)
        case nil:
            break
        }
    }

    func stop() {
        local.stop()
        aware?.stop()
        role = nil
    }

    func clearSession() {
        local.clearSession()
        aware?.clearSession()
        role = nil
    }

    private var selectedTransport: SessionAssetTransport? {
        switch routeController.selectedRoute {
        case .localLAN: local
        case .wifiAware: aware
        case nil: nil
        }
    }

    private func handle(_ event: SessionAssetEvent, from route: SessionTransportRoute) {
        switch role {
        case .guide:
            handler?(event)
        case .guest where routeController.selectedRoute == route:
            handler?(event)
        case .guest, nil:
            break
        }
    }
}
