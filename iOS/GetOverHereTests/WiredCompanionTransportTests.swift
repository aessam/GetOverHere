import CryptoKit
import Foundation
import LocalLinkSecurity
import Network
import os
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite(.serialized) @MainActor
struct WiredCompanionTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func actualTLSFixedLaneRoundtripAndConfirmedReconnectAfterExpiry() async throws {
        let interface = try await loopbackInterface()
        let guideIdentity = try LocalLinkIdentity(privateKey: .init())
        let companionIdentity = try LocalLinkIdentity(privateKey: .init())
        let room = UUID(), guideID = UUID()
        let signer = GuideFrameSigner(sessionID: room, guideID: guideID)
        let record = BluetoothRoomRecord(roomID: room, guideID: guideID, name: "Component", isAndroid: false, isLocked: false, admissionVersion: 2)
        let offer = try GatewayPairingMessage(role: .offer, pairingID: UUID(), roomID: room, guideID: guideID,
            expiresAtMilliseconds: LiveWiredCompanionTransport.wallMilliseconds + 2_000,
            certificateFingerprint: guideIdentity.certificateFingerprint, guideKeyFingerprint: Data(SHA256.hash(data: signer.publicKey)),
            offerCertificateFingerprint: guideIdentity.certificateFingerprint, host: "127.0.0.1", port: GatewayProtocol.servicePort)
        let response = try GatewayPairingMessage(role: .response, pairingID: offer.pairingID, roomID: room, guideID: guideID,
            expiresAtMilliseconds: offer.expiresAtMilliseconds, certificateFingerprint: companionIdentity.certificateFingerprint,
            guideKeyFingerprint: offer.guideKeyFingerprint, offerCertificateFingerprint: offer.certificateFingerprint, host: "", port: 0)
        let endpoint = try GatewayEchoEndpoint()
        let port = try await endpoint.start()
        let guide = LiveWiredCompanionTransport(loopbackComponentTest: (), localConnect: { requested in
            #expect(requested == 50_002)
            return NearbyTCPConnection(port: port)
        })
        let discovery = ComponentWiredDiscovery()
        let companion = LiveWiredCompanionTransport(loopbackComponentTest: (), discovery: discovery)
        defer { companion.stop(); guide.stop(); endpoint.stop() }
        var guideReady = false
        guide.onState = { if $0 == "waiting-for-companion" { guideReady = true } }
        try guide.startGuide(identity: guideIdentity, offer: offer, response: response, interface: interface) { (record, signer.publicKey) }
        try await eventually { guideReady }
        try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface)
        try await eventually { companion.descriptor != nil }
        #expect(companion.descriptor?.record == record)
        let firstGeneration = try #require(companion.descriptor?.generation)
        let stream = try await companion.connect(lane: .asset, roomID: room)
        let bytes = Data((0..<1_024).map { UInt8($0 % 251) })
        try await stream.write(bytes)
        #expect(try await stream.readExactly(bytes.count) == bytes)
        stream.close()

        let invalidGuide = LiveWiredCompanionTransport()
        #expect(throws: NearbyConnectionError.self) {
            try invalidGuide.startGuide(identity: guideIdentity, offer: offer, response: response, interface: interface) { (record, signer.publicKey) }
        }
        try await Task.sleep(for: .milliseconds(2_100))
        companion.stop()
        try await eventually { guide.descriptor == nil }
        try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface, confirmedAssociation: true)
        try await eventually { companion.descriptor != nil }
        let nextGeneration = try #require(companion.descriptor?.generation)
        #expect(nextGeneration > firstGeneration)
        #expect(discovery.requestedPairingIDs == [offer.pairingID])
        let restored = try await companion.connect(lane: .asset, roomID: room)
        try await restored.write(bytes)
        #expect(try await restored.readExactly(bytes.count) == bytes)
        restored.close()

        // A second authenticated control connection cannot replace a healthy association.
        let intruder = try rawConnection(identity: companionIdentity, pin: guideIdentity.certificateFingerprint, interface: interface)
        defer { intruder.close() }
        try await intruder.write(try GatewayLaneRequest(pairingID: offer.pairingID, roomID: room, generation: 0, lane: .hubControl).encode())
        #expect(try await intruder.readExactly(1) == Data([GatewayLaneRequest.Reply.capacity.rawValue]))
        #expect(guide.descriptor?.generation == nextGeneration)
        intruder.close()

        let stale = try rawConnection(identity: companionIdentity, pin: guideIdentity.certificateFingerprint, interface: interface)
        defer { stale.close() }
        try await stale.write(try GatewayLaneRequest(pairingID: offer.pairingID, roomID: room, generation: firstGeneration, lane: .asset).encode())
        #expect(try await stale.readExactly(1) == Data([GatewayLaneRequest.Reply.rejected.rawValue]))
        stale.close()

        companion.stop()
        try await eventually { guide.descriptor == nil }
        let unresponsive = try rawConnection(identity: companionIdentity, pin: guideIdentity.certificateFingerprint, interface: interface)
        defer { unresponsive.close() }
        try await unresponsive.write(try GatewayLaneRequest(pairingID: offer.pairingID, roomID: room, generation: 0, lane: .hubControl).encode())
        #expect(try await unresponsive.readExactly(1) == Data([0]))
        let length = try await unresponsive.readExactly(2).reduce(0) { ($0 << 8) | Int($1) }
        _ = try GatewayRoomDescriptor.decode(try await unresponsive.readExactly(length))
        // Deliberately omit the hub-control heartbeat ACK. The guide must withdraw
        // even though TCP's send buffer accepted the descriptor.
        try await eventually { guide.descriptor == nil }
        #expect(try await unresponsive.read(maximum: 1).isEmpty)
        #expect(guide.connectionCount == 0)

        // Rebind and change the discovered remote address/family without
        // changing the expired enrollment, pins, room, or guide identity.
        guide.suspend()
        #expect(guide.peerCertificateSHA256 == companionIdentity.certificateFingerprint.map { String(format: "%02x", $0) }.joined())
        guideReady = false
        try guide.resumeGuide(on: interface)
        try await eventually { guideReady }
        discovery.nextHost = "::1"
        try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface, confirmedAssociation: true)
        try await eventually { companion.descriptor != nil }
        #expect(companion.descriptor?.record == record)
        #expect(try #require(companion.descriptor?.generation) > nextGeneration)
        let changedAddress = try await companion.connect(lane: .asset, roomID: room)
        let resumeOffset = 387
        let tail = Data(bytes.dropFirst(resumeOffset))
        try await changedAddress.write(tail)
        #expect(try await changedAddress.readExactly(tail.count) == tail)
        guide.suspend()
        #expect(try await changedAddress.read(maximum: 1).isEmpty)
        try await eventually { companion.descriptor == nil }
        #expect(guide.connectionCount == 0)
        changedAddress.close()

        // A discovered endpoint advertising the right public room and pairing
        // still cannot substitute a different guide certificate.
        let rogueIdentity = try LocalLinkIdentity(privateKey: .init())
        let rogueOffer = try GatewayPairingMessage(role: .offer, pairingID: offer.pairingID, roomID: room, guideID: guideID,
            expiresAtMilliseconds: LiveWiredCompanionTransport.wallMilliseconds + 60_000,
            certificateFingerprint: rogueIdentity.certificateFingerprint, guideKeyFingerprint: offer.guideKeyFingerprint,
            offerCertificateFingerprint: rogueIdentity.certificateFingerprint, host: "127.0.0.1", port: GatewayProtocol.servicePort)
        let rogueResponse = try GatewayPairingMessage(role: .response, pairingID: offer.pairingID, roomID: room, guideID: guideID,
            expiresAtMilliseconds: rogueOffer.expiresAtMilliseconds, certificateFingerprint: companionIdentity.certificateFingerprint,
            guideKeyFingerprint: offer.guideKeyFingerprint, offerCertificateFingerprint: rogueIdentity.certificateFingerprint, host: "", port: 0)
        let rogue = LiveWiredCompanionTransport(loopbackComponentTest: ())
        defer { rogue.stop() }
        var rogueReady = false, rejected = false
        rogue.onState = { if $0 == "waiting-for-companion" { rogueReady = true } }
        try rogue.startGuide(identity: rogueIdentity, offer: rogueOffer, response: rogueResponse, interface: interface) { (record, signer.publicKey) }
        try await eventually { rogueReady }
        companion.onError = { _ in rejected = true }
        try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface, confirmedAssociation: true)
        try await eventually { rejected }
        #expect(companion.descriptor == nil)
        #expect(companion.connectionCount == 0)
        #expect(companion.peerCertificateSHA256 == guideIdentity.certificateFingerprint.map { String(format: "%02x", $0) }.joined())
        let stillLocal = NearbyTCPConnection(port: port)
        defer { stillLocal.close() }
        try await stillLocal.write(bytes)
        #expect(try await stillLocal.readExactly(bytes.count) == bytes)
        guide.stop()
        #expect(throws: GatewayProtocolError.self) { try guide.resumeGuide(on: interface) }
        #expect(throws: GatewayProtocolError.self) {
            try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface)
        }
    }

    @Test func discoveryMatchesOnlyEnrolledInstanceAndSelectedInterface() async throws {
        let interface = try await loopbackInterface()
        let pairing = UUID()
        let valid = NWEndpoint.service(name: WiredHubDiscovery.instanceName(pairing), type: WiredHubDiscovery.serviceType,
            domain: "local.", interface: interface)
        #expect(WiredHubDiscovery.matches(valid, pairingID: pairing, interface: interface))
        #expect(!WiredHubDiscovery.matches(valid, pairingID: UUID(), interface: interface))
        for candidate in [
            NWEndpoint.service(name: WiredHubDiscovery.instanceName(pairing), type: "_goh-peer._tcp", domain: "local.", interface: interface),
            .service(name: WiredHubDiscovery.instanceName(pairing), type: WiredHubDiscovery.serviceType, domain: "example.com", interface: interface),
            .service(name: WiredHubDiscovery.instanceName(pairing), type: WiredHubDiscovery.serviceType, domain: "local.", interface: nil),
            .hostPort(host: "127.0.0.1", port: 50104),
        ] { #expect(!WiredHubDiscovery.matches(candidate, pairingID: pairing, interface: interface)) }
    }

    @Test func cancelledDiscoveryCannotResurrectRemovedAssociation() async throws {
        let interface = try await loopbackInterface()
        let discovery = WiredHubDiscovery()
        let task = Task { try await discovery.endpoint(pairingID: UUID(), interface: interface) }
        await Task.yield()
        task.cancel(); discovery.stop()
        do { _ = try await task.value; Issue.record("Cancelled discovery unexpectedly resolved") }
        catch { #expect(error is CancellationError) }
    }

    @Test(arguments: [false, true])
    func completedDescriptorCannotPublishAfterStopOrReplacement(replace: Bool) async throws {
        let interface = try await loopbackInterface()
        let guideIdentity = try LocalLinkIdentity(privateKey: .init())
        let companionIdentity = try LocalLinkIdentity(privateKey: .init())
        let room = UUID(), guideID = UUID()
        let signer = GuideFrameSigner(sessionID: room, guideID: guideID)
        let record = BluetoothRoomRecord(roomID: room, guideID: guideID, name: "Cancellation boundary",
            isAndroid: false, isLocked: false, admissionVersion: 2)
        let offer = try GatewayPairingMessage(role: .offer, pairingID: UUID(), roomID: room, guideID: guideID,
            expiresAtMilliseconds: LiveWiredCompanionTransport.wallMilliseconds + 60_000,
            certificateFingerprint: guideIdentity.certificateFingerprint, guideKeyFingerprint: Data(SHA256.hash(data: signer.publicKey)),
            offerCertificateFingerprint: guideIdentity.certificateFingerprint, host: "127.0.0.1", port: GatewayProtocol.servicePort)
        let response = try GatewayPairingMessage(role: .response, pairingID: offer.pairingID, roomID: room, guideID: guideID,
            expiresAtMilliseconds: offer.expiresAtMilliseconds, certificateFingerprint: companionIdentity.certificateFingerprint,
            guideKeyFingerprint: offer.guideKeyFingerprint, offerCertificateFingerprint: offer.certificateFingerprint, host: "", port: 0)
        let guide = LiveWiredCompanionTransport(loopbackComponentTest: ())
        let companion = LiveWiredCompanionTransport(loopbackComponentTest: (), discovery: ComponentWiredDiscovery())
        defer { companion.stop(); guide.stop() }
        var ready = false, intercepted = false
        var publications: [GatewayRoomDescriptor] = []
        var states: [String] = []
        var replacement: Task<Void, any Error>?
        guide.onState = { if $0 == "waiting-for-companion" { ready = true } }
        companion.onDescriptor = { if let value = $0 { publications.append(value) } }
        companion.onState = { states.append($0) }
        companion.descriptorDecodedForComponentTest = {
            companion.descriptorDecodedForComponentTest = nil
            intercepted = true
            companion.stop()
            if replace {
                replacement = Task {
                    try await eventually { guide.descriptor == nil }
                    try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface, confirmedAssociation: true)
                }
            }
        }
        try guide.startGuide(identity: guideIdentity, offer: offer, response: response, interface: interface) { (record, signer.publicKey) }
        try await eventually { ready }
        try companion.startCompanion(identity: companionIdentity, offer: offer, interface: interface)
        try await eventually { intercepted }
        if replace {
            try await #require(replacement).value
            try await eventually { companion.descriptor != nil }
            #expect(publications.count == 1, "Only the replacement may publish, never the completed old read")
            #expect(states.filter { $0 == "forwarding" }.count == 1)
        } else {
            #expect(publications.isEmpty)
            #expect(!states.contains("forwarding"))
            #expect(companion.descriptor == nil)
            #expect(companion.connectionCount == 0)
        }
    }

    private func rawConnection(identity: LocalLinkIdentity, pin: Data, interface: NWInterface) throws -> NearbyTCPConnection {
        let parameters = NWParameters(tls: try identity.tlsOptions(expectedPeerPin: pin), tcp: NWProtocolTCP.Options())
        parameters.requiredInterface = interface
        return NearbyTCPConnection(NWConnection(host: "127.0.0.1", port: .init(rawValue: GatewayProtocol.servicePort)!, using: parameters))
    }

    private func eventually(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for gateway state", sourceLocation: sourceLocation)
        throw GatewayProtocolError.expired
    }

    private func loopbackInterface() async throws -> NWInterface {
        let endpoint = try GatewayEchoEndpoint()
        let port = try await endpoint.start()
        let connection = NearbyTCPConnection(port: port)
        defer { connection.close(); endpoint.stop() }
        try await connection.write(Data([42]))
        #expect(try await connection.readExactly(1) == Data([42]))
        return try #require(connection.currentPath?.availableInterfaces.first { $0.type == .loopback },
            "A connected loopback TCP endpoint must expose its interface: \(String(describing: connection.currentPath))")
    }
}

@MainActor private final class ComponentWiredDiscovery: WiredHubDiscovering {
    var nextHost = "127.0.0.1"
    var requestedPairingIDs: [UUID] = []
    func endpoint(pairingID: UUID, interface: NWInterface) async throws -> NWEndpoint {
        requestedPairingIDs.append(pairingID)
        return .hostPort(host: .init(nextHost), port: 50104)
    }
    func stop() {}
}

@MainActor private final class GatewayEchoEndpoint {
    let listener: NWListener
    var connections: [NWConnection] = []
    var ready: CheckedContinuation<UInt16, any Error>?
    init() throws {
        let parameters = NearbyTCPConnection.parameters()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                let stream = NearbyTCPConnection(connection)
                do {
                    while true {
                        let bytes = try await stream.read(maximum: 16_384)
                        if bytes.isEmpty { break }
                        try await stream.write(bytes)
                    }
                } catch { Logger.transport.debug("Component echo connection ended: \(error.localizedDescription)") }
                stream.close()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, let ready else { return }
                if case .ready = state, let port = listener.port?.rawValue { self.ready = nil; ready.resume(returning: port) }
                if case .failed(let error) = state { self.ready = nil; ready.resume(throwing: error) }
            }
        }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}
