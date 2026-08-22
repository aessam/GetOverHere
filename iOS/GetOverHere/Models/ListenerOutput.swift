import Foundation

enum ListenerOutput: String, CaseIterable, Sendable {
    case privateAudio
    case speaker

    var title: String {
        switch self {
        case .privateAudio: "Earpiece"
        case .speaker: "Speaker"
        }
    }

    var systemImage: String {
        switch self {
        case .privateAudio: "ear"
        case .speaker: "speaker.wave.3.fill"
        }
    }

    var toggled: Self {
        self == .privateAudio ? .speaker : .privateAudio
    }
}
