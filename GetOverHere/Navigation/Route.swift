import Foundation

enum AppTab: Hashable, CaseIterable {
    case nearby
    case chats
    case files
    case walkieTalkie

    var title: String {
        switch self {
        case .nearby: "Nearby"
        case .chats: "Chats"
        case .files: "Files"
        case .walkieTalkie: "Walkie-Talkie"
        }
    }

    var icon: String {
        switch self {
        case .nearby: "antenna.radiowaves.left.and.right"
        case .chats: "bubble.left.and.bubble.right"
        case .files: "doc.on.doc"
        case .walkieTalkie: "waveform"
        }
    }
}

enum ChatRoute: Hashable {
    case room(PeerInfo)
}

enum WalkieTalkieRoute: Hashable {
    case channel(UUID)
}
