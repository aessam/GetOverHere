import Foundation

extension ChannelService.ConnectionState {
    /// Guest header status text. A FAILED state renders the recorded failure reason, so a
    /// protocol version mismatch is visible instead of the generic label.
    nonisolated func guestStatusText(error: String?) -> String {
        switch self {
        case .idle: "IDLE"
        case .connecting: "CONNECTING"
        case .connected: "LISTENING"
        case let .reconnecting(attempt): "RECONNECTING \(attempt)/5"
        case .failed: error ?? "CONNECTION FAILED"
        }
    }
}
