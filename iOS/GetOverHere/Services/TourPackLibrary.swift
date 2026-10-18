import Foundation
import Observation
import TourSessionCore

/// Tour packs this device has imported (ADR-080). Drives the "Tour ready" badge for a room whose
/// record advertises a pack (ADR-082); readiness itself is still decided by the session manifest's hashes.
@Observable
@MainActor
final class TourPackLibrary {
    struct Entry: Codable, Equatable {
        let packID: UUID
        let manifestVersion: UInt64
        let displayName: String
    }

    @ObservationIgnored private let fileURL: URL
    private(set) var entries: [Entry]

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
        } else {
            entries = []
        }
    }

    /// True when an imported pack has this ID at this version or newer.
    func holds(_ advert: TourPackAdvert) -> Bool {
        entries.contains { $0.packID == advert.packID && $0.manifestVersion >= advert.manifestVersion }
    }

    func record(_ manifest: TourPackManifestPayload) throws {
        entries.removeAll { $0.packID == manifest.packID }
        entries.append(Entry(packID: manifest.packID, manifestVersion: manifest.manifestVersion,
                             displayName: manifest.displayName))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
