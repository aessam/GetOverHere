import Foundation

struct Channel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    let createdBy: String

    static let townsquare = Channel(
        id: "00000000-0000-0000-0000-000000000000",
        name: "Townsquare",
        createdAt: .distantPast,
        createdBy: "system"
    )
}
