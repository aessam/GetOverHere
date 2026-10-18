import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Tour pack import into the asset cache (ADR-080)")
struct TourPackImporterTests {
    private struct Workspace {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHerePackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var packURL: URL { root.appending(path: "fixture.gohtour") }
        var cacheRoot: URL { root.appending(path: "cache", directoryHint: .isDirectory) }

        func write(_ data: Data) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: packURL)
        }

        func remove() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary pack cleanup failed: \(error.localizedDescription)") }
        }
    }

    private static func hashes() -> [String] {
        TourSessionFixtures.tourPackFixtureAssets().map { Data(SHA256.hash(data: $0)).lowercaseHex }
    }

    @Test("Import stores every asset under its hash; a second import finds them cached")
    func importsAndDeduplicates() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }
        try workspace.write(try TourSessionFixtures.tourPackFixture())
        let cache = try FileTourAssetCache(rootDirectory: workspace.cacheRoot)
        // Small chunks so multi-chunk ingestion is exercised on 13-byte assets.
        let importer = TourPackImporter(cache: cache, chunkSize: 4)

        let first = try await importer.importPack(at: workspace.packURL)
        #expect(first.imported == 3 && first.alreadyCached == 0)
        #expect(first.manifest.displayName == "Fixture Tour")
        for (hash, bytes) in zip(Self.hashes(), TourSessionFixtures.tourPackFixtureAssets()) {
            let url = try #require(try await cache.readyURL(sha256: hash, expectedLength: UInt64(bytes.count)))
            #expect(try Data(contentsOf: url) == bytes)
        }

        let second = try await importer.importPack(at: workspace.packURL)
        #expect(second.imported == 0 && second.alreadyCached == 3)
    }

    @Test("A corrupted pack writes nothing to the cache")
    func corruptedPackWritesNothing() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }
        var bytes = [UInt8](try TourSessionFixtures.tourPackFixture())
        bytes[471] ^= 0x01 // first asset byte; the trailer no longer matches
        try workspace.write(Data(bytes))
        let cache = try FileTourAssetCache(rootDirectory: workspace.cacheRoot)

        await #expect(throws: TourPackError.trailerMismatch) {
            try await TourPackImporter(cache: cache).importPack(at: workspace.packURL)
        }
        for (hash, asset) in zip(Self.hashes(), TourSessionFixtures.tourPackFixtureAssets()) {
            #expect(try await cache.readyURL(sha256: hash, expectedLength: UInt64(asset.count)) == nil)
            #expect(try await cache.resumeOffset(sha256: hash, expectedLength: UInt64(asset.count)) == 0)
        }
    }

    @Test("A partial left by an over-the-air transfer is replaced, not appended to")
    func replacesPartial() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }
        try workspace.write(try TourSessionFixtures.tourPackFixture())
        let cache = try FileTourAssetCache(rootDirectory: workspace.cacheRoot)
        let asset = TourSessionFixtures.tourPackFixtureAssets()[0]
        let hash = Self.hashes()[0]
        _ = try await cache.ingest(try AssetChunkPayload(sha256: hash, offset: 0, totalLength: UInt64(asset.count),
                                                         bytes: asset.prefix(5)))

        let outcome = try await TourPackImporter(cache: cache).importPack(at: workspace.packURL)
        #expect(outcome.imported == 3)
        let url = try #require(try await cache.readyURL(sha256: hash, expectedLength: UInt64(asset.count)))
        #expect(try Data(contentsOf: url) == asset)
    }
}
