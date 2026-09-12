import CryptoKit
import Foundation
import LocalLinkSecurity
import Network
import TourSessionCore
import UIKit

/// Owns setup and radio publication, not a second ChannelService or guide session.
@MainActor @Observable
final class GatewaySessionCoordinator {
    enum Role: String { case none, guide, companion }
    private(set) var role: Role = .none
    private(set) var state = "stopped"
    private(set) var error: String?
    private(set) var nativeBranchState = "stopped"
    private(set) var nativeBranchError: String?
    private(set) var offer: GatewayPairingMessage?
    private(set) var response: GatewayPairingMessage?
    private(set) var publicQRCode = ""
    private(set) var roomName = ""
    let wiredInterfaces = WiredInterfaceMonitor()
    let transport = LiveWiredCompanionTransport()
    var keepAwake = true { didSet { updateAwake() } }
    private var previousIdleTimer: Bool?
    private let idleTimerOwner = UUID()
    private let service: ChannelService
    private let control: LocalControlPlane
    private var identity: LocalLinkIdentity?
    private var enrollmentTimeout: Task<Void, Never>?
    private var confirmedAssociation = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var wiredWatchTask: Task<Void, Never>?
    private var observedWiredSelection: String?
    private var guideConfirmedByUser = false
    private var savedDiscovery: (bluetooth: Bool, aware: Bool, applePeer: Bool)?
    private var deferredGuideAppleRestore: Bool?

    init(service: ChannelService, control: LocalControlPlane) {
        self.service = service; self.control = control
        service.onGuideSessionEnding = { [weak self] in
            guard let self else { return }
            if role == .guide { stop(guideEnding: true) }
            restoreDeferredGuideDiscovery()
        }
        control.onApplePeerState = { [weak self] in self?.nativeBranchState = $0 }
        control.onApplePeerError = { [weak self] in self?.nativeBranchError = $0 }
        transport.onError = { [weak self] message in
            guard let self else { return }
            self.error = message
            self.scheduleReconnect()
        }
        transport.onState = { [weak self] state in
            guard let self else { return }
            self.state = state
            if state == "forwarding" || state == "companion-connected" {
                self.confirmedAssociation = true; self.enrollmentTimeout?.cancel(); self.reconnectAttempt = 0
                self.reconnectTask?.cancel(); self.reconnectTask = nil
                self.publicQRCode = ""; self.error = nil
            }
        }
        transport.onDescriptor = { [weak self] descriptor in
            guard let self, role == .companion else { return }
            roomName = descriptor?.record.name ?? ""
            control.publishCompanion(descriptor?.record, connector: descriptor == nil ? nil : transport,
                generation: descriptor?.generation)
            updateAwake()
        }
    }

    func beginGuidePairing() throws {
        guard role == .none, let hosted = service.gatewayHostedRoom,
              let interface = wiredInterfaces.selected,
              let host = WiredInterfaceMonitor.addresses(on: interface.name).first else {
            throw NearbyConnectionError.unavailable
        }
        let identity = try LocalLinkIdentityStore.loadOrCreate()
        let offer = try GatewayPairingMessage(role: .offer, pairingID: UUID(), roomID: hosted.0.roomID,
            guideID: hosted.0.guideID,
            expiresAtMilliseconds: LiveWiredCompanionTransport.wallMilliseconds + GatewayProtocol.enrollmentLifetimeMilliseconds,
            certificateFingerprint: identity.certificateFingerprint,
            guideKeyFingerprint: Data(SHA256.hash(data: hosted.1)),
            offerCertificateFingerprint: identity.certificateFingerprint, host: host, port: GatewayProtocol.servicePort)
        self.identity = identity; self.offer = offer; response = nil
        saveDiscovery()
        role = .guide; roomName = hosted.0.name; state = "scan-offer-on-companion"; error = nil
        publicQRCode = offer.qrString
        service.applePeerDiscoveryEnabled = true
        scheduleEnrollmentExpiry()
    }

    func receivePairingQR(_ text: String) throws {
        let message = try GatewayPairingMessage.decodeQR(text.trimmingCharacters(in: .whitespacesAndNewlines))
        try message.validate(nowMilliseconds: LiveWiredCompanionTransport.wallMilliseconds)
        if message.role == .offer {
            guard role == .none, service.activeChannelID == nil, service.connectionState != .connecting else {
                throw GatewayProtocolError.unconfirmed
            }
            let identity = try LocalLinkIdentityStore.loadOrCreate()
            let response = try GatewayPairingMessage(role: .response, pairingID: message.pairingID,
                roomID: message.roomID, guideID: message.guideID, expiresAtMilliseconds: message.expiresAtMilliseconds,
                certificateFingerprint: identity.certificateFingerprint, guideKeyFingerprint: message.guideKeyFingerprint,
                offerCertificateFingerprint: message.certificateFingerprint, host: "", port: 0)
            self.identity = identity; offer = message; self.response = response
            saveDiscovery()
            publicQRCode = response.qrString; role = .companion; state = "scan-response-on-guide"; error = nil
            service.companionModeActive = true
            service.bluetoothDiscoveryEnabled = false; service.awareDiscoveryEnabled = false
            control.setApplePeerMode(.off)
            scheduleEnrollmentExpiry(); updateAwake()
        } else {
            guard role == .guide, let offer else { throw GatewayProtocolError.mismatchedPairing }
            try message.validateResponse(to: offer, nowMilliseconds: LiveWiredCompanionTransport.wallMilliseconds)
            response = message; state = "awaiting-guide-confirmation"
        }
    }

    /// No listener is accepted until the guide has scanned the response and explicitly confirmed.
    func confirmCompanion() throws {
        guard role == .guide, state == "awaiting-guide-confirmation", let identity, let offer, let response,
              let interface = wiredInterfaces.selected else { throw GatewayProtocolError.unconfirmed }
        try transport.startGuide(identity: identity, offer: offer, response: response, interface: interface) { [weak service] in
            service?.gatewayHostedRoom
        }
        guideConfirmedByUser = true
        startWiredWatch()
        state = "starting-wired-listener"
    }

    func connectCompanion() throws {
        guard role == .companion, let identity, let offer, let interface = wiredInterfaces.selected else {
            throw NearbyConnectionError.unavailable
        }
        try transport.startCompanion(identity: identity, offer: offer, interface: interface,
            confirmedAssociation: confirmedAssociation)
        startWiredWatch()
        state = "connecting-wired-guide"
    }

    func stop(guideEnding: Bool = false) {
        let preserveGuideBranch = role == .guide && !guideEnding && service.isCreator
        reconnectTask?.cancel(); reconnectTask = nil; confirmedAssociation = false; reconnectAttempt = 0
        wiredWatchTask?.cancel(); wiredWatchTask = nil; observedWiredSelection = nil; guideConfirmedByUser = false
        enrollmentTimeout?.cancel(); enrollmentTimeout = nil
        transport.stop()
        // Removing an upstream companion must not close an independent guide's
        // local Apple guest lanes. Only a companion owns this proxy publication.
        if role == .companion { control.publishCompanion(nil, connector: nil) }
        role = .none; state = "stopped"; publicQRCode = ""; roomName = ""
        nativeBranchError = nil
        identity = nil; offer = nil; response = nil; service.companionModeActive = false
        restoreAwake()
        if let savedDiscovery {
            service.bluetoothDiscoveryEnabled = savedDiscovery.bluetooth
            service.awareDiscoveryEnabled = savedDiscovery.aware
            if preserveGuideBranch {
                if deferredGuideAppleRestore == nil { deferredGuideAppleRestore = savedDiscovery.applePeer }
            } else {
                service.applePeerDiscoveryEnabled = savedDiscovery.applePeer
            }
            self.savedDiscovery = nil
        }
        if guideEnding { restoreDeferredGuideDiscovery() }
    }

    func report(_ error: any Error) { self.error = error.localizedDescription }
    func retryNativeBranch() {
        guard role != .none else { return }
        nativeBranchError = nil
        control.retryApplePeerPublication()
    }
    private func scheduleReconnect() {
        guard role == .companion || (role == .guide && guideConfirmedByUser), reconnectTask == nil, reconnectAttempt < 5 else { return }
        reconnectAttempt += 1
        state = "reconnecting-wired-guide"
        let delay = min(8, 1 << (reconnectAttempt - 1))
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            reconnectTask = nil
            do {
                if role == .companion { try connectCompanion() }
                else if role == .guide, guideConfirmedByUser {
                    guard let interface = wiredInterfaces.selected else { throw NearbyConnectionError.unavailable }
                    try transport.resumeGuide(on: interface)
                }
            }
            catch { report(error); scheduleReconnect() }
        }
    }
    private func startWiredWatch() {
        guard wiredWatchTask == nil else { return }
        observedWiredSelection = wiredSelectionSignature
        wiredWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, role != .none else { return }
                let selection = wiredSelectionSignature
                guard selection != observedWiredSelection else { continue }
                observedWiredSelection = selection
                reconnectTask?.cancel(); reconnectTask = nil; reconnectAttempt = 0
                transport.suspend()
                if selection == nil { state = "waiting-for-wired-interface" }
                else { scheduleReconnect() }
            }
        }
    }
    private var wiredSelectionSignature: String? {
        guard let interface = wiredInterfaces.selected else { return nil }
        let addresses = WiredInterfaceMonitor.addresses(on: interface.name).sorted()
        guard !addresses.isEmpty else { return nil }
        return "\(interface.index):\(interface.name):" + addresses.joined(separator: ",")
    }
    private func scheduleEnrollmentExpiry() {
        enrollmentTimeout?.cancel()
        guard let offer else { return }
        let now = LiveWiredCompanionTransport.wallMilliseconds
        let remaining = offer.expiresAtMilliseconds > now ? offer.expiresAtMilliseconds - now : 0
        enrollmentTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(remaining)) } catch { return }
            guard let self else { return }
            stop(); error = "Companion pairing expired. Start a new pairing."
        }
    }
    private func saveDiscovery() {
        guard savedDiscovery == nil else { return }
        savedDiscovery = (service.bluetoothDiscoveryEnabled, service.awareDiscoveryEnabled, service.applePeerDiscoveryEnabled)
    }
    private func restoreDeferredGuideDiscovery() {
        guard let enabled = deferredGuideAppleRestore else { return }
        deferredGuideAppleRestore = nil
        service.applePeerDiscoveryEnabled = enabled
    }
    private func updateAwake() {
        if role == .companion, keepAwake {
            if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            IdleTimerOwnership.acquire(idleTimerOwner)
        } else { restoreAwake() }
    }
    private func restoreAwake() {
        if previousIdleTimer != nil { IdleTimerOwnership.release(idleTimerOwner); previousIdleTimer = nil }
    }
}
