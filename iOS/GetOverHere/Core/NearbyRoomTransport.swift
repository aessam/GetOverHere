import Foundation
import TourSessionCore

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
    func prepareNearbyGuest(roomID: UUID) async throws -> String
    func stopNearbyGuest()
}
