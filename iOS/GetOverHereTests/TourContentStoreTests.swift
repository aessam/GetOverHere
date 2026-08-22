import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Tour content store", .serialized)
struct TourContentStoreTests {
    @Test("Imported slides are hashed, persisted, and ordered")
    @MainActor
    func importedSlidesAreManifested() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereContentStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TourContentStore(rootDirectory: root)
        let packID = UUID()
        let firstBytes = Data("gate".utf8)
        let secondBytes = Data("court".utf8)

        try store.beginPack(packID: packID, displayName: "Alhambra")
        let first = try await store.importSlide(data: firstBytes, mimeType: "image/jpeg")
        let second = try await store.importSlide(data: secondBytes, mimeType: "image/png")
        let manifest = try store.manifestPayload()

        #expect(manifest.packID == packID)
        #expect(manifest.manifestVersion == 2)
        #expect(manifest.assets.map(\.assetID) == [first.assetID, second.assetID])
        #expect(manifest.assets.map(\.order) == [0, 1])
        #expect(first.sha256 == SHA256.hash(data: firstBytes).map { String(format: "%02x", $0) }.joined())
        #expect(try Data(contentsOf: #require(store.sourcesByAssetID[first.assetID])) == firstBytes)
        #expect(try Data(contentsOf: #require(store.sourcesByAssetID[second.assetID])) == secondBytes)
    }

    @Test("Slides can be reordered and removed without deleting unrelated assets")
    @MainActor
    func reorderAndRemoveSlides() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereContentEdit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TourContentStore(rootDirectory: root)
        try store.beginPack(packID: UUID(), displayName: "Alhambra")
        let first = try await store.importSlide(data: Data("one".utf8), mimeType: "image/jpeg")
        let second = try await store.importSlide(data: Data("two".utf8), mimeType: "image/jpeg")
        let third = try await store.importSlide(data: Data("three".utf8), mimeType: "image/jpeg")

        try store.moveSlide(assetID: third.assetID, to: 0)
        #expect(try store.manifestPayload().assets.filter { $0.kind == .slide }.map(\.assetID) == [
            third.assetID, first.assetID, second.assetID,
        ])
        #expect(try store.manifestPayload().assets.filter { $0.kind == .slide }.map(\.order) == [0, 1, 2])

        try store.removeSlide(assetID: first.assetID)
        let manifest = try store.manifestPayload()
        #expect(manifest.manifestVersion == 5)
        #expect(manifest.assets.filter { $0.kind == .slide }.map(\.assetID) == [third.assetID, second.assetID])
        #expect(manifest.assets.filter { $0.kind == .slide }.map(\.order) == [0, 1])
        #expect(store.sourcesByAssetID[first.assetID] == nil)
    }

    @Test("Offline map is copied, hashed, and replaces the previous map")
    @MainActor
    func offlineMapIsManifested() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereMapStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereMap-\(UUID().uuidString).pmtiles")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: archive)
        }
        let archiveBytes = try OfflineMapPackTests.minimalArchiveData()
        try archiveBytes.write(to: archive)
        let store = try TourContentStore(rootDirectory: root)
        try store.beginPack(packID: UUID(), displayName: "Alhambra")

        try await store.importOfflineMap(
            styleData: OfflineMapPackTests.styleData(),
            archiveURL: archive
        )

        let manifest = try store.manifestPayload()
        #expect(manifest.manifestVersion == 1)
        #expect(manifest.assets.filter { $0.kind == .mapStyle }.count == 1)
        #expect(manifest.assets.filter { $0.kind == .mapArchive }.count == 1)
        let storedArchive = try #require(manifest.assets.first { $0.kind == .mapArchive })
        #expect(try Data(contentsOf: #require(store.sourcesByAssetID[storedArchive.assetID])) == archiveBytes)
    }
}
