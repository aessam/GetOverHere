import Foundation

/// Cross-platform message format. Android will encode/decode the same JSON structure.
enum TransportMessage: Codable, Sendable {
    case text(TextPayload)
    case walkieTalkieControl(WalkieTalkieControl)
    case channelAnnounce(ChannelAnnounce)
    case fileHeader(FileHeader)
    case fileChunk(FileChunk)

    struct TextPayload: Codable, Sendable, Identifiable {
        let id: String
        let channelID: String
        let senderID: String
        let senderName: String
        let content: String
        let timestamp: Date
        let replyTo: String?

        init(
            id: String = UUID().uuidString,
            channelID: String,
            senderID: String,
            senderName: String,
            content: String,
            timestamp: Date = Date(),
            replyTo: String? = nil
        ) {
            self.id = id
            self.channelID = channelID
            self.senderID = senderID
            self.senderName = senderName
            self.content = content
            self.timestamp = timestamp
            self.replyTo = replyTo
        }
    }

    enum WalkieTalkieControl: Codable, Sendable {
        case requestFloor(channelID: String, peerID: String, peerName: String)
        case grantFloor(channelID: String, peerID: String)
        case releaseFloor(channelID: String, peerID: String)
        case denyFloor(channelID: String, reason: String)
    }

    struct ChannelAnnounce: Codable, Sendable {
        let channelID: String
        let channelName: String
        let createdAt: Date
        let createdBy: String
    }

    struct FileHeader: Codable, Sendable {
        let transferID: String
        let channelID: String
        let senderID: String
        let senderName: String
        let fileName: String
        let fileSize: Int
        let mimeType: String
        let timestamp: Date
    }

    struct FileChunk: Codable, Sendable {
        let transferID: String
        let index: Int
        let totalChunks: Int
        let data: String // Base64-encoded chunk data
    }
}
