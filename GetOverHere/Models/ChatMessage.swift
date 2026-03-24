import Foundation
import SwiftData

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var senderID: String
    var senderName: String
    var content: String
    var timestamp: Date
    var isFromMe: Bool
    var peerID: String

    init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        content: String,
        timestamp: Date = Date(),
        isFromMe: Bool,
        peerID: String
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.peerID = peerID
    }
}
