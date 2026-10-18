import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Prepared tours on the guide (ADR-080 DSCN-1)")
@MainActor
struct PreparedTourStoreTests {
    @Test("Create, add slides, export a .gohtour the core reads back, reload, remove")
    func lifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHerePrepared-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary prepared-tour cleanup failed: \(error.localizedDescription)") }
        }
        let store = try PreparedTourStore(rootDirectory: root.appending(path: "tours", directoryHint: .isDirectory))
        let created = try store.create(name: "Old Town")
        #expect(created.manifestVersion == 1 && created.assets.isEmpty)
        await #expect(throws: PreparedTourError.emptyTour) { try store.export(created.packID, to: root) }

        let pages = [Data("page one".utf8), Data("page two".utf8), Data("page one".utf8)]
        let updated = try await store.addSlides(pages.map { .init(data: $0, mimeType: "image/jpeg") }, to: created.packID)
        #expect(updated.manifestVersion == 2)
        #expect(updated.assets.map(\.order) == [0, 1, 2])
        #expect(Set(updated.assets.map(\.sha256)).count == 2, "identical pages share one file")

        let url = try store.export(created.packID, to: root)
        #expect(url.lastPathComponent == "Old Town.gohtour")
        let (layout, assets) = try TourPackArchive.read(try Data(contentsOf: url))
        #expect(layout.manifest == updated)
        #expect(Set(assets.values) == Set(pages))

        let reloaded = try PreparedTourStore(rootDirectory: root.appending(path: "tours", directoryHint: .isDirectory))
        #expect(reloaded.tours == [updated])
        try reloaded.remove(created.packID)
        #expect(reloaded.tours.isEmpty)
        #expect(try PreparedTourStore(rootDirectory: root.appending(path: "tours", directoryHint: .isDirectory)).tours.isEmpty)
    }
}
