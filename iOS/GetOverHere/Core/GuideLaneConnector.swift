import Foundation
import TourSessionCore

/// Fixed application destinations only. A companion implementation opens USB TLS,
/// never another guide session, encoder, credential store or arbitrary TCP proxy.
@MainActor
protocol GuideLaneConnector: AnyObject {
    func connect(lane: NearbyLaneRequest.Lane, roomID: UUID) async throws -> any NearbyByteConnection
}
