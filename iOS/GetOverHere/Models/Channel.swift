import Foundation

struct Channel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    let createdBy: String
    /// Speaker's WiFi IP for TCP audio connection (from channelAnnounce).
    var audioHostIP: String?
    var roomAdmissionVersion: Int? = nil
    var isRoomLocked: Bool = true

    static let townsquare = Channel(
        id: "00000000-0000-0000-0000-000000000000",
        name: "Townsquare",
        createdAt: .distantPast,
        createdBy: "system"
    )
}
