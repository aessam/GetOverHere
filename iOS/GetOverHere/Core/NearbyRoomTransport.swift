import Foundation
import TourSessionCore

/// An adapter owned by the native route, not a LAN endpoint. Preparation binds the
/// local lanes; admission and signed lane handshakes must still prove the remote peer.
nonisolated struct NearbyGuestRoute: Equatable, Sendable {
    let adapterHost: String
    let transport: SessionTransportRoute
    let roomID: UUID
    let routeID: UUID
    /// Set when this room is an island hosted by a bridge (ADR-081): lanes authenticate to that bridge.
    let relayHost: RelayHostAdvert?

    init(adapterHost: String, transport: SessionTransportRoute, roomID: UUID, routeID: UUID, relayHost: RelayHostAdvert? = nil) {
        precondition(adapterHost == "127.0.0.1")
        precondition(transport == .bluetooth || transport == .wifiAware || transport == .applePeer)
        self.adapterHost = adapterHost
        self.transport = transport
        self.roomID = roomID
        self.routeID = routeID
        self.relayHost = relayHost
    }
}

/// Discovery owns radio endpoints. Public records never manufacture a LAN address.
@MainActor
protocol NearbyRoomTransport: AnyObject {
    var onRoom: ((BluetoothRoomRecord) -> Void)? { get set }
    var onLost: ((UUID) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func setMode(_ mode: BluetoothDiscoveryMode)
    func publish(_ record: BluetoothRoomRecord?)
    func connect(roomID: UUID) async throws -> any NearbyByteConnection
    func stop()
}

@MainActor
protocol NearbyRouteControl: AnyObject {
    var onNearbyError: ((String) -> Void)? { get set }
    var usesBluetoothGuestRoute: Bool { get }
    func setAwareDiscoveryMode(_ mode: BluetoothDiscoveryMode)
    func canConnectNearby(roomID: UUID) -> Bool
    func prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID) async throws -> NearbyGuestRoute
    func stopNearbyGuest()
}
