import CryptoKit
import Foundation
import Observation
import TourSessionCore

enum PreparedTourError: LocalizedError, Equatable {
    case unknownTour(UUID)
    case emptyTour
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case .unknownTour: "This prepared tour no longer exists"
        case .emptyTour: "Add slides before sharing or going live"
        case let .missingAsset(hash): "A file of this tour is missing (\(hash.prefix(12)))"
        }
    }
}

/// Tours a guide prepares before going live (ADR-080 DSCN-1). Each tour lives in
/// `PreparedTours/<packID>/`: `manifest.goh` holds the `TourPackManifestPayload` bytes and `assets/<sha256>`
/// holds each file once. Going live publishes the same descriptors, so guests that imported the shared
/// `.gohtour` already hold every hash.
@Observable
@MainActor
final class PreparedTourStore {
    private(set) var tours: [TourPackManifestPayload] = []
    @ObservationIgnored private let rootDirectory: URL

    init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        tours = try Self.loadAll(from: rootDirectory)
    }

    func create(name: String) throws -> TourPackManifestPayload {
        let manifest = try TourPackManifestPayload(packID: UUID(), manifestVersion: 1, displayName: name, assets: [])
        try save(manifest)
        return manifest
    }

    /// Appends slides in order. Each import bumps the manifest version, which the room record advertises.
    func addSlides(_ slides: [ChannelService.SlideImport], to packID: UUID) async throws -> TourPackManifestPayload {
        let current = try tour(packID)
        var assets = current.assets
        var order = (assets.map(\.order).max() ?? 0) + (assets.isEmpty ? 0 : 1)
        let directory = assetDirectory(packID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for slide in slides {
            let hash = Data(SHA256.hash(data: slide.data)).lowercaseHex
            let destination = directory.appending(path: hash)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try slide.data.write(to: destination, options: .atomic)
            }
            assets.append(try TourAssetDescriptor(assetID: UUID().uuidString.lowercased(), kind: .slide, sha256: hash,
                                                  byteLength: UInt64(slide.data.count), order: order,
                                                  mimeType: slide.mimeType))
            order += 1
        }
        let updated = try TourPackManifestPayload(packID: packID, manifestVersion: current.manifestVersion + 1,
                                                  displayName: current.displayName, assets: assets)
        try save(updated)
        return updated
    }

    func remove(_ packID: UUID) throws {
        try FileManager.default.removeItem(at: tourDirectory(packID))
        tours.removeAll { $0.packID == packID }
    }

    func tour(_ packID: UUID) throws -> TourPackManifestPayload {
        guard let tour = tours.first(where: { $0.packID == packID }) else { throw PreparedTourError.unknownTour(packID) }
        return tour
    }

    /// Everything `ChannelService.createChannel(name:prepared:)` needs to present this tour.
    func launch(_ packID: UUID) throws -> ChannelService.PreparedTourLaunch {
        let manifest = try tour(packID)
        guard !manifest.assets.isEmpty else { throw PreparedTourError.emptyTour }
        return .init(manifest: manifest, sourcesByAssetID: Dictionary(uniqueKeysWithValues: manifest.assets.map {
            ($0.assetID, assetURL($0.sha256, in: packID))
        }))
    }

    /// Where the bytes for `sha256` live, for going live and for export.
    func assetURL(_ sha256: String, in packID: UUID) -> URL { assetDirectory(packID).appending(path: sha256) }

    /// Writes `<name>.gohtour` into `directory`, streaming each file once, and returns its URL.
    func export(_ packID: UUID, to directory: URL) throws -> URL {
        let manifest = try tour(packID)
        guard !manifest.assets.isEmpty else { throw PreparedTourError.emptyTour }
        let (prefix, layout) = try TourPackArchive.prefix(for: manifest)
        let safeName = manifest.displayName.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
        let url = directory.appending(path: "\(safeName.isEmpty ? "Tour" : safeName).gohtour")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: url)
        defer {
            do { try output.close() } catch {
                fputs("Prepared tour: close failed (\(String(describing: type(of: error))))\n", stderr)
            }
        }
        var hasher = SHA256()
        try output.write(contentsOf: prefix)
        hasher.update(data: prefix)
        for entry in layout.entries {
            let source = assetURL(entry.sha256Hex, in: packID)
            guard let input = try? FileHandle(forReadingFrom: source) else {
                throw PreparedTourError.missingAsset(entry.sha256Hex)
            }
            defer {
                do { try input.close() } catch {
                    fputs("Prepared tour: close failed (\(String(describing: type(of: error))))\n", stderr)
                }
            }
            var fileHasher = SHA256()
            var copied: UInt64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                fileHasher.update(data: chunk)
                copied += UInt64(chunk.count)
            }
            guard copied == entry.byteLength, Data(fileHasher.finalize()) == entry.sha256 else {
                throw PreparedTourError.missingAsset(entry.sha256Hex)
            }
        }
        try output.write(contentsOf: Data(hasher.finalize()))
        return url
    }

    private func save(_ manifest: TourPackManifestPayload) throws {
        let directory = tourDirectory(manifest.packID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.encode().write(to: directory.appending(path: "manifest.goh"), options: .atomic)
        tours.removeAll { $0.packID == manifest.packID }
        tours.append(manifest)
        tours.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func tourDirectory(_ packID: UUID) -> URL {
        rootDirectory.appending(path: packID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func assetDirectory(_ packID: UUID) -> URL {
        tourDirectory(packID).appending(path: "assets", directoryHint: .isDirectory)
    }

    private static func loadAll(from root: URL) throws -> [TourPackManifestPayload] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try TourPackManifestPayload.decode(Data(contentsOf: $0.appending(path: "manifest.goh"))) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
