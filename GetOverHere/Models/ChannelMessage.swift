import Foundation

struct ChannelMessage: Identifiable, Sendable {
    let id: String
    let channelID: String
    let senderID: String
    let senderName: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool

    // File attachment (nil for text-only messages)
    var fileName: String?
    var fileSize: Int?
    var mimeType: String?
    var localFilePath: String?

    var replyToID: String?
}
