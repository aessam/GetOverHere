import Foundation

struct Channel: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var memberIDs: Set<String>
    let createdAt: Date

    init(id: UUID = UUID(), name: String, memberIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.createdAt = Date()
    }
}
