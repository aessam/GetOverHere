import Foundation

/// Cross-platform message format with custom Codable to ensure iOS↔Android wire compatibility.
/// Swift's auto-synthesized Codable wraps unnamed enum values with "_0" which Android doesn't send.
enum TransportMessage: Sendable {
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
        let data: String
    }
}

// MARK: - Custom Codable (no _0 wrapper — matches Android wire format)

extension TransportMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, walkieTalkieControl, channelAnnounce, fileHeader, fileChunk
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let v): try container.encode(v, forKey: .text)
        case .walkieTalkieControl(let v): try container.encode(v, forKey: .walkieTalkieControl)
        case .channelAnnounce(let v): try container.encode(v, forKey: .channelAnnounce)
        case .fileHeader(let v): try container.encode(v, forKey: .fileHeader)
        case .fileChunk(let v): try container.encode(v, forKey: .fileChunk)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? container.decode(TextPayload.self, forKey: .text) {
            self = .text(v)
        } else if let v = try? container.decode(WalkieTalkieControl.self, forKey: .walkieTalkieControl) {
            self = .walkieTalkieControl(v)
        } else if let v = try? container.decode(ChannelAnnounce.self, forKey: .channelAnnounce) {
            self = .channelAnnounce(v)
        } else if let v = try? container.decode(FileHeader.self, forKey: .fileHeader) {
            self = .fileHeader(v)
        } else if let v = try? container.decode(FileChunk.self, forKey: .fileChunk) {
            self = .fileChunk(v)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No matching case"))
        }
    }
}
