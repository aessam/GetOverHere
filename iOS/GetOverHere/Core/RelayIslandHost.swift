import Foundation
import os
import TourSessionCore

/// Publishes the island room and routes accepted island connections through a `GuideLaneConnector` (ADR-081 P4).
@MainActor
protocol IslandAdvertiserInterface: AnyObject {
    func start(record: BluetoothRoomRecord, connector: any GuideLaneConnector)
    func stop()
}

/// Island advertiser over Apple peer-to-peer Wi-Fi; its own transport, so the guest's discovery mode is untouched.
@MainActor
final class ApplePeerIslandAdvertiser: IslandAdvertiserInterface {
    private static let logger = Logger(subsystem: "com.aens.GetOverHere", category: "ApplePeerIsland")
    private var transport: ApplePeerRoomTransport?

    func start(record: BluetoothRoomRecord, connector: any GuideLaneConnector) {
        let current = transport ?? ApplePeerRoomTransport()
        current.onError = { Self.logger.error("Island advertiser: \($0, privacy: .public)") }
        current.guideConnector = connector
        current.publish(record)
        current.setMode(.advertising)
        transport = current
    }

    func stop() {
        transport?.setMode(.off)
        transport?.publish(nil)
        transport = nil
    }
}

/**
 The bridge side of a cross-island tour on an ordinary guest (ADR-081 P4; mirrors Android `RelayIslandHost`). Every
 guide frame the guest's lanes open is fed to `RelayHub`. When the guide's signed `bridgeAssignment` names this guest,
 the island starts: one loopback `RelayLaneServer` per media lane, and an island advertiser whose admission lane goes
 to the guest's own nearby adapter (127.0.0.1:50003), which tunnels it to the guide. Another assignment, `close()`,
 or leaving the tour closes the island. Upstream lanes and their ports are untouched.
 */
@MainActor
final class RelayIslandHost: GuideLaneConnector {
    private static let logger = Logger(subsystem: "com.aens.GetOverHere", category: "RelayIslandHost")

    nonisolated let hub: RelayHub
    private let bridgeID: UUID
    private let sessionID: UUID
    private let guideID: UUID
    private let credential: SessionCredential
    private let upstreamRecord: BluetoothRoomRecord
    private let advertiser: IslandAdvertiserInterface
    private let assetFile: @Sendable (String) -> URL?
    private let forwardUpstream: @Sendable (RelayUpstreamRecord) -> Void
    private let admissionPort: UInt16
    private var servers: [SessionLane: RelayLaneServer] = [:]
    private var islandGeneration: UInt64?
    private var closed = false
    /// Last assignment generation handed to the main actor, so each one is scheduled once.
    nonisolated private let scheduled = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    init(bridgeID: UUID, sessionID: UUID, guideID: UUID, credential: SessionCredential, verifier: GuideFrameVerifier,
         upstreamRecord: BluetoothRoomRecord, advertiser: IslandAdvertiserInterface,
         assetFile: @escaping @Sendable (String) -> URL?,
         forwardUpstream: @escaping @Sendable (RelayUpstreamRecord) -> Void = { _ in },
         admissionPort: UInt16 = NearbyLaneRequest.Lane.admission.localPort!) {
        self.bridgeID = bridgeID
        self.sessionID = sessionID
        self.guideID = guideID
        self.credential = credential
        self.upstreamRecord = upstreamRecord
        self.advertiser = advertiser
        self.assetFile = assetFile
        self.forwardUpstream = forwardUpstream
        self.admissionPort = admissionPort
        weak var weakSelf: RelayIslandHost?
        hub = RelayHub(bridgeID: bridgeID, verifier: verifier, credential: credential,
            onRouteFault: { lane, reason in Self.logger.error("Relay route fault on \(String(describing: lane)): \(reason, privacy: .public)") },
            // Called on a lane thread after the hub released its lock: tear down on the main actor.
            onIslandRevoked: { value in
                Task { @MainActor in weakSelf?.stopIsland("guide assigned \(value.bridgeID) (generation \(value.generation))") }
            })
        weakSelf = self
    }

    /// Raw GOS1 bytes of a guide frame the guest just opened on `lane` (any thread).
    nonisolated func onUpstreamFrame(lane: SessionLane, frame: Data) {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        hub.onUpstreamFrame(lane: lane, frame: frame, receivedAtMilliseconds: now, nowMilliseconds: now)
        guard let assigned = hub.assignment else { return }
        let fresh = scheduled.withLock { last in
            guard last != assigned.generation else { return false }
            last = assigned.generation
            return true
        }
        if fresh { Task { @MainActor [weak self] in self?.startIsland(assigned) } }
    }

    /// Lane ports while the island runs (tests and diagnostics).
    var lanePorts: [SessionLane: UInt16] { servers.mapValues(\.port) }

    func close() {
        closed = true
        stopIsland("bridge stopped")
    }

    private func startIsland(_ assigned: BridgeAssignmentPayload) {
        guard !closed, hub.assignment?.generation == assigned.generation, islandGeneration != assigned.generation else { return }
        if servers.isEmpty {
            do {
                for lane in [SessionLane.realtime, .control, .asset] {
                    servers[lane] = try RelayLaneServer(lane: lane, credential: credential, sessionID: sessionID, guideID: guideID,
                                                        bridgeID: bridgeID, hub: hub, assetFile: assetFile, onUpstream: forwardUpstream)
                }
            } catch {
                Self.logger.error("Relay island listeners failed: \(String(describing: error), privacy: .public)")
                stopIsland("listeners failed")
                return
            }
        }
        islandGeneration = assigned.generation
        let record = BluetoothRoomRecord(roomID: upstreamRecord.roomID, guideID: upstreamRecord.guideID, name: upstreamRecord.name,
            isAndroid: upstreamRecord.isAndroid, isLocked: upstreamRecord.isLocked, admissionVersion: upstreamRecord.admissionVersion,
            pack: upstreamRecord.pack, relayHost: RelayHostAdvert(hostID: bridgeID, bridgeGeneration: assigned.generation))
        advertiser.start(record: record, connector: self)
        Self.logger.info("Relay island up: generation \(assigned.generation), ports \(String(describing: self.lanePorts), privacy: .public)")
    }

    private func stopIsland(_ reason: String) {
        guard !servers.isEmpty || islandGeneration != nil else { return }
        advertiser.stop()
        servers.values.forEach { $0.close() }
        servers.removeAll()
        hub.closeIsland()
        islandGeneration = nil
        scheduled.withLock { $0 = nil }
        Self.logger.info("Relay island down: \(reason, privacy: .public)")
    }

    func connect(lane: NearbyLaneRequest.Lane, roomID: UUID) async throws -> any NearbyByteConnection {
        let port: UInt16? = switch lane {
        case .realtime: servers[.realtime]?.port
        case .control: servers[.control]?.port
        case .asset: servers[.asset]?.port
        case .admission: admissionPort
        case .metadata: nil
        }
        guard let port else { throw NearbyConnectionError.unavailable }
        return NearbyTCPConnection(port: port)
    }
}
