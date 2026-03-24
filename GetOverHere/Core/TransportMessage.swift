import Foundation

/// Cross-platform message format. Android will encode/decode the same JSON structure.
enum TransportMessage: Codable, Sendable {
    case text(TextPayload)
    case walkieTalkieControl(WalkieTalkieControl)

    struct TextPayload: Codable, Sendable, Identifiable {
        let id: UUID
        let senderID: String
        let senderName: String
        let content: String
        let timestamp: Date

        init(
            id: UUID = UUID(),
            senderID: String,
            senderName: String,
            content: String,
            timestamp: Date = Date()
        ) {
            self.id = id
            self.senderID = senderID
            self.senderName = senderName
            self.content = content
            self.timestamp = timestamp
        }
    }

    enum WalkieTalkieControl: Codable, Sendable {
        case requestFloor(channelID: String, peerID: String, peerName: String)
        case grantFloor(channelID: String, peerID: String)
        case releaseFloor(channelID: String, peerID: String)
        case denyFloor(channelID: String, reason: String)
        case joinChannel(channelID: String, channelName: String, peerID: String, peerName: String)
        case leaveChannel(channelID: String, peerID: String)
    }
}
