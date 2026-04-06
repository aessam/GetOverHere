import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aens.GetOverHere"

    static let transport = Logger(subsystem: subsystem, category: "Transport")
    static let chat = Logger(subsystem: subsystem, category: "Chat")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let fileShare = Logger(subsystem: subsystem, category: "FileShare")
    static let walkieTalkie = Logger(subsystem: subsystem, category: "WalkieTalkie")
    static let channel = Logger(subsystem: subsystem, category: "Channel")
}
