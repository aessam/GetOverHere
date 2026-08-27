import Foundation
import os

extension Logger {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aens.GetOverHere"

    nonisolated static let transport = Logger(subsystem: subsystem, category: "Transport")
    nonisolated static let chat = Logger(subsystem: subsystem, category: "Chat")
    nonisolated static let audio = Logger(subsystem: subsystem, category: "Audio")
    nonisolated static let fileShare = Logger(subsystem: subsystem, category: "FileShare")
    nonisolated static let walkieTalkie = Logger(subsystem: subsystem, category: "WalkieTalkie")
    nonisolated static let channel = Logger(subsystem: subsystem, category: "Channel")
}
