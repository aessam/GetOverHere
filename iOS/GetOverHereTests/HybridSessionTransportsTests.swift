import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Hybrid session transports", .serialized)
struct HybridSessionTransportsTests {
    @Test("Guest route lease keeps audio, control, and assets on one route")
    @MainActor
    func guestUsesOneRouteAcrossEveryLane() async {
        let routes = HybridSessionRouteController()
        #expect(routes.select(.localLAN))
        #expect(!routes.select(.wifiAware))

        let localAudio = RecordingAudioPlane()
        let awareAudio = RecordingAudioPlane()
        let localControl = RecordingHybridControlTransport()
        let awareControl = RecordingHybridControlTransport()
        let localAsset = RecordingHybridAssetTransport()
        let awareAsset = RecordingHybridAssetTransport()
        let audio = HybridAudioPlane(
            local: localAudio,
            aware: awareAudio,
            routeController: routes,
            setLocalHostIP: { _ in }
        )
        let control = HybridSessionControlTransport(
            local: localControl,
            aware: awareControl,
            routeController: routes
        )
        let asset = HybridSessionAssetTransport(
            local: localAsset,
            aware: awareAsset,
            routeController: routes
        )

        var connectedEvents = 0
        control.setEventHandler { event in
            if case .connected = event { connectedEvents += 1 }
        }
        audio.startListening(channelID: UUID().uuidString) { _ in }
        control.startGuest()
        asset.startGuest()
        awareControl.emit(.connected)
        localControl.emit(.connected)
        await Task.yield()
        await Task.yield()
        audio.sendAudio(Data([1]))
        control.send(kind: .bearingSnapshot, payload: Data([2]))
        asset.send(kind: .assetStatus, payload: Data([3]), to: nil)

        #expect(connectedEvents == 1)
        #expect(localAudio.guestStarts == 1)
        #expect(localControl.guestStarts == 1)
        #expect(localAsset.guestStarts == 1)
        #expect(localAudio.sent.count == 1)
        #expect(localControl.sentKinds == [.bearingSnapshot])
        #expect(localAsset.sentKinds == [.assetStatus])
        #expect(awareAudio.guestStarts == 0)
        #expect(awareControl.guestStarts == 0)
        #expect(awareAsset.guestStarts == 0)
        #expect(awareAudio.sent.isEmpty)
        #expect(awareControl.sentKinds.isEmpty)
        #expect(awareAsset.sentKinds.isEmpty)

        audio.stop()
        control.stop()
        asset.stop()
        routes.replace(with: .wifiAware)
        audio.startListening(channelID: UUID().uuidString) { _ in }
        control.startGuest()
        asset.startGuest()
        audio.sendAudio(Data([4]))
        control.send(kind: .bearingSnapshot, payload: Data([5]))
        asset.send(kind: .assetStatus, payload: Data([6]), to: nil)

        #expect(awareAudio.guestStarts == 1)
        #expect(awareControl.guestStarts == 1)
        #expect(awareAsset.guestStarts == 1)
        #expect(awareAudio.sent.count == 1)
        #expect(awareControl.sentKinds == [.bearingSnapshot])
        #expect(awareAsset.sentKinds == [.assetStatus])
        #expect(localAudio.sent.count == 1)
        #expect(localControl.sentKinds == [.bearingSnapshot])
        #expect(localAsset.sentKinds == [.assetStatus])
    }

    @Test("Guide hosts and sends every lane over LAN and Aware")
    @MainActor
    func guideRunsBothRoutes() {
        let routes = HybridSessionRouteController()
        let localAudio = RecordingAudioPlane()
        let awareAudio = RecordingAudioPlane()
        let localControl = RecordingHybridControlTransport()
        let awareControl = RecordingHybridControlTransport()
        let localAsset = RecordingHybridAssetTransport()
        let awareAsset = RecordingHybridAssetTransport()
        let audio = HybridAudioPlane(
            local: localAudio,
            aware: awareAudio,
            routeController: routes,
            setLocalHostIP: { _ in }
        )
        let control = HybridSessionControlTransport(
            local: localControl,
            aware: awareControl,
            routeController: routes
        )
        let asset = HybridSessionAssetTransport(
            local: localAsset,
            aware: awareAsset,
            routeController: routes
        )

        audio.startBroadcasting(channelID: UUID().uuidString, quality: .standard)
        control.startGuide()
        asset.startGuide()
        audio.sendAudio(Data([1]))
        control.send(kind: .bearingSnapshot, payload: Data([2]))
        asset.send(kind: .assetStatus, payload: Data([3]), to: nil)

        #expect(localAudio.guideStarts == 1)
        #expect(awareAudio.guideStarts == 1)
        #expect(localAudio.sent.count == 1)
        #expect(awareAudio.sent.count == 1)
        #expect(localControl.guideStarts == 1)
        #expect(awareControl.guideStarts == 1)
        #expect(localControl.sentKinds == [.bearingSnapshot])
        #expect(awareControl.sentKinds == [.bearingSnapshot])
        #expect(localAsset.guideStarts == 1)
        #expect(awareAsset.guideStarts == 1)
        #expect(localAsset.sentKinds == [.assetStatus])
        #expect(awareAsset.sentKinds == [.assetStatus])
    }
}

@MainActor
private final class RecordingAudioPlane: AudioPlane {
    var isActive = false
    var guideStarts = 0
    var guestStarts = 0
    var sent: [Data] = []

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        isActive = true
        guideStarts += 1
    }

    func sendAudio(_ data: Data) {
        sent.append(data)
    }

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        isActive = true
        guestStarts += 1
    }

    func stop() {
        isActive = false
    }

    func clearSession() { stop() }
}

@MainActor
private final class RecordingHybridControlTransport: SessionControlTransport {
    var isActive = false
    var hostIP: String?
    var guideStarts = 0
    var guestStarts = 0
    var sentKinds: [SessionMessageKind] = []
    private var handler: (@Sendable (SessionControlEvent) -> Void)?

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {}

    func setEventHandler(_ handler: (@Sendable (SessionControlEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() {
        isActive = true
        guideStarts += 1
    }

    func startGuest() {
        isActive = true
        guestStarts += 1
    }

    func send(kind: SessionMessageKind, payload: Data) {
        sentKinds.append(kind)
    }

    func stop() {
        isActive = false
    }

    func clearSession() { stop() }

    func emit(_ event: SessionControlEvent) {
        handler?(event)
    }
}

@MainActor
private final class RecordingHybridAssetTransport: SessionAssetTransport {
    var isActive = false
    var hostIP: String?
    var guideStarts = 0
    var guestStarts = 0
    var sentKinds: [SessionMessageKind] = []
    private var handler: (@Sendable (SessionAssetEvent) -> Void)?

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {}

    func setEventHandler(_ handler: (@Sendable (SessionAssetEvent) -> Void)?) {
        self.handler = handler
    }

    func startGuide() {
        isActive = true
        guideStarts += 1
    }

    func startGuest() {
        isActive = true
        guestStarts += 1
    }

    func send(kind: SessionMessageKind, payload: Data, to participantID: UUID?) {
        sentKinds.append(kind)
    }

    func stop() {
        isActive = false
    }

    func clearSession() { stop() }
}
