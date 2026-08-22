import Foundation
import MapLibre
import Testing
import UIKit
@testable import GetOverHere

@Suite("Offline map pack")
struct OfflineMapPackTests {
    @Test("Local PMTiles placeholder resolves to app-owned file")
    func localArchiveResolution() throws {
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "map \(UUID().uuidString).pmtiles")
        let archiveBytes = try Self.minimalArchiveData()
        try archiveBytes.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        try OfflineMapPack.validateArchive(at: archive)

        let configuration = try OfflineMapPack.configuration(
            styleData: Self.styleData(),
            archiveURL: archive
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(configuration.styleJSON.utf8)) as? [String: Any]
        )
        let sources = try #require(object["sources"] as? [String: Any])
        let source = try #require(sources["tour"] as? [String: Any])
        let resolvedURL = try #require(source["url"] as? String)
        #expect(resolvedURL.hasPrefix("pmtiles://file:///"))
        #expect(resolvedURL.contains("%20"))
        #expect(resolvedURL != OfflineMapPack.archivePlaceholder)
    }

    @Test("Network resources are rejected")
    func remoteResourcesAreRejected() {
        let style = """
        {"version":8,"sources":{"tour":{"type":"vector","url":"https://example.com/map.json"}},"layers":[]}
        """.data(using: .utf8)!

        #expect(throws: OfflineMapPackError.self) {
            try OfflineMapPack.configuration(
                styleData: style,
                archiveURL: URL(fileURLWithPath: "/tmp/map.pmtiles")
            )
        }
    }

    @Test("PMTiles magic without a complete header is rejected")
    func truncatedArchiveIsRejected() throws {
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "truncated-\(UUID().uuidString).pmtiles")
        try Data("PMTiles\u{3}".utf8).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }

        #expect(throws: OfflineMapPackError.self) {
            try OfflineMapPack.validateArchive(at: archive)
        }
    }

    @Test("PMTiles sections outside the file are rejected")
    func outOfBoundsArchiveIsRejected() throws {
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "invalid-offset-\(UUID().uuidString).pmtiles")
        var archiveBytes = try Self.minimalArchiveData()
        Self.writeUInt64LE(UInt64.max, to: &archiveBytes, at: 56)
        try archiveBytes.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }

        #expect(throws: OfflineMapPackError.self) {
            try OfflineMapPack.validateArchive(at: archive)
        }
    }

    @Test("MapLibre renders the minimal local PMTiles archive", .timeLimit(.minutes(1)))
    @MainActor
    func minimalArchiveRendersInMapLibre() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "map-render-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appending(path: "minimal.pmtiles")
        try Self.minimalArchiveData().write(to: archive)
        let configuration = try OfflineMapPack.configuration(
            styleData: Self.styleData(),
            archiveURL: archive
        )

        let styleURL = directory.appending(path: "style.json")
        try Data(configuration.styleJSON.utf8).write(to: styleURL)
        let camera = MLNMapCamera(
            lookingAtCenter: .init(latitude: 0, longitude: 0),
            altitude: 1_000,
            pitch: 0,
            heading: 0
        )
        let options = MLNMapSnapshotOptions(
            styleURL: styleURL,
            camera: camera,
            size: CGSize(width: 128, height: 128)
        )
        options.zoomLevel = 0
        options.scale = 1
        options.showsLogo = false
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()
        #expect(snapshot.image.size == CGSize(width: 128, height: 128))
    }

    static func styleData() -> Data {
        """
        {"version":8,"sources":{"tour":{"type":"raster","url":"getoverhere://map-archive","tileSize":256}},"layers":[{"id":"tour","type":"raster","source":"tour"}]}
        """.data(using: .utf8)!
    }

    /// PMTiles v3 reference layout with one z0/x0/y0 purple PNG tile.
    /// The PNG is the public fixture from protomaps/go-pmtiles/examples/minimal.go.
    static func minimalArchiveData() throws -> Data {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mM0NLxTDwADmAG/Djok1gAAAABJRU5ErkJggg=="
        ))
        let directory = Data([1, 0, 1, UInt8(png.count), 1])
        let metadata = Data("{}".utf8)
        let rootOffset: UInt64 = 127
        let metadataOffset = rootOffset + UInt64(directory.count)
        let tileOffset = metadataOffset + UInt64(metadata.count)
        var header = Data(repeating: 0, count: 127)
        header.replaceSubrange(0 ..< 8, with: Data("PMTiles\u{3}".utf8))
        writeUInt64LE(rootOffset, to: &header, at: 8)
        writeUInt64LE(UInt64(directory.count), to: &header, at: 16)
        writeUInt64LE(metadataOffset, to: &header, at: 24)
        writeUInt64LE(UInt64(metadata.count), to: &header, at: 32)
        writeUInt64LE(tileOffset, to: &header, at: 40)
        writeUInt64LE(0, to: &header, at: 48)
        writeUInt64LE(tileOffset, to: &header, at: 56)
        writeUInt64LE(UInt64(png.count), to: &header, at: 64)
        writeUInt64LE(1, to: &header, at: 72)
        writeUInt64LE(1, to: &header, at: 80)
        writeUInt64LE(1, to: &header, at: 88)
        header[96] = 1
        header[97] = 1
        header[98] = 1
        header[99] = 2
        return header + directory + metadata + png
    }

    private static func writeUInt64LE(_ value: UInt64, to data: inout Data, at offset: Int) {
        for index in 0 ..< 8 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
    }
}
