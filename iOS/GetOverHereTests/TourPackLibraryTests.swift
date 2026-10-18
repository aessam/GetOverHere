import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Imported tour pack library (ADR-080/082)")
@MainActor
struct TourPackLibraryTests {
    @Test("A recorded pack satisfies adverts at its version or older and survives a reload")
    func recordsAndReloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHerePackLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary library cleanup failed: \(error.localizedDescription)") }
        }
        let file = root.appending(path: "ImportedTourPacks.json")
        let manifest = try TourPackArchive.read(try TourSessionFixtures.tourPackFixture()).layout.manifest

        let library = try TourPackLibrary(fileURL: file)
        #expect(!library.holds(TourPackAdvert(packID: manifest.packID, manifestVersion: 1)))
        try library.record(manifest)
        #expect(library.holds(TourPackAdvert(packID: manifest.packID, manifestVersion: manifest.manifestVersion)))
        #expect(library.holds(TourPackAdvert(packID: manifest.packID, manifestVersion: manifest.manifestVersion - 1)))
        #expect(!library.holds(TourPackAdvert(packID: manifest.packID, manifestVersion: manifest.manifestVersion + 1)),
                "a newer advertised version needs the newer pack")
        #expect(!library.holds(TourPackAdvert(packID: UUID(), manifestVersion: 1)))

        let reloaded = try TourPackLibrary(fileURL: file)
        #expect(reloaded.entries == library.entries)
        try reloaded.record(manifest)
        #expect(reloaded.entries.count == 1, "re-importing replaces, never duplicates")
    }
}
