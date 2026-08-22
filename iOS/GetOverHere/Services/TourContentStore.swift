import CryptoKit
import Foundation
import Observation
import TourSessionCore

enum TourContentStoreError: LocalizedError {
    case packNotStarted
    case sourceDirectoryUnavailable(URL)
    case unknownSlide(String)
    case invalidSlideIndex(Int)

    var errorDescription: String? {
        switch self {
        case .packNotStarted:
            "No tour pack is active"
        case let .sourceDirectoryUnavailable(url):
            "Could not create tour content directory at \(url.path)"
        case let .unknownSlide(assetID):
            "Unknown slide asset ID \(assetID)"
        case let .invalidSlideIndex(index):
            "Slide index \(index) is out of bounds"
        }
    }
}

@Observable
@MainActor
final class TourContentStore {
    private(set) var packID: UUID?
    private(set) var displayName = ""
    private(set) var manifestVersion: UInt64 = 0
    private(set) var assets: [TourAssetDescriptor] = []
    private(set) var sourcesByAssetID: [String: URL] = [:]

    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private var nextSlideOrder: UInt32 = 0

    init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try Self.createDirectory(rootDirectory)
    }

    func beginPack(packID: UUID, displayName: String) throws {
        let sourceDirectory = sourceDirectory(for: packID)
        try Self.createDirectory(sourceDirectory)
        self.packID = packID
        self.displayName = displayName
        manifestVersion = 0
        assets = []
        sourcesByAssetID = [:]
        nextSlideOrder = 0
    }

    func importSlide(data: Data, mimeType: String) async throws -> TourAssetDescriptor {
        guard let packID else { throw TourContentStoreError.packNotStarted }
        let assetID = UUID().uuidString.lowercased()
        let order = nextSlideOrder
        nextSlideOrder &+= 1
        let destination = sourceDirectory(for: packID)
            .appending(path: "\(assetID).\(Self.fileExtension(for: mimeType))", directoryHint: .notDirectory)
        let stored = try await Self.persist(data: data, destination: destination)
        let descriptor = try TourAssetDescriptor(
            assetID: assetID,
            kind: .slide,
            sha256: stored.sha256,
            byteLength: stored.byteLength,
            order: order,
            mimeType: mimeType
        )
        assets.append(descriptor)
        assets.sort { ($0.order, $0.assetID) < ($1.order, $1.assetID) }
        sourcesByAssetID[assetID] = destination
        manifestVersion &+= 1
        return descriptor
    }

    func importOfflineMap(styleData: Data, archiveURL: URL) async throws {
        guard let packID else { throw TourContentStoreError.packNotStarted }
        try OfflineMapPack.validateArchive(at: archiveURL)
        _ = try OfflineMapPack.configuration(styleData: styleData, archiveURL: archiveURL)

        let styleAssetID = UUID().uuidString.lowercased()
        let archiveAssetID = UUID().uuidString.lowercased()
        let directory = sourceDirectory(for: packID)
        let styleDestination = directory.appending(path: "\(styleAssetID).json")
        let archiveDestination = directory.appending(path: "\(archiveAssetID).pmtiles")
        let styleStored = try await Self.persist(data: styleData, destination: styleDestination)
        let archiveStored = try await Self.persist(file: archiveURL, destination: archiveDestination)

        let styleDescriptor = try TourAssetDescriptor(
            assetID: styleAssetID,
            kind: .mapStyle,
            sha256: styleStored.sha256,
            byteLength: styleStored.byteLength,
            order: 0,
            mimeType: "application/vnd.mapbox.style+json"
        )
        let archiveDescriptor = try TourAssetDescriptor(
            assetID: archiveAssetID,
            kind: .mapArchive,
            sha256: archiveStored.sha256,
            byteLength: archiveStored.byteLength,
            order: 0,
            mimeType: "application/vnd.pmtiles"
        )

        let replacedIDs = Set(
            assets.filter { $0.kind == .mapStyle || $0.kind == .mapArchive }.map(\.assetID)
        )
        assets.removeAll { replacedIDs.contains($0.assetID) }
        for assetID in replacedIDs { sourcesByAssetID.removeValue(forKey: assetID) }
        assets.append(contentsOf: [styleDescriptor, archiveDescriptor])
        sourcesByAssetID[styleAssetID] = styleDestination
        sourcesByAssetID[archiveAssetID] = archiveDestination
        manifestVersion &+= 1
    }

    func moveSlide(assetID: String, to destinationIndex: Int) throws {
        var slides = orderedSlides
        guard let sourceIndex = slides.firstIndex(where: { $0.assetID == assetID }) else {
            throw TourContentStoreError.unknownSlide(assetID)
        }
        guard slides.indices.contains(destinationIndex) else {
            throw TourContentStoreError.invalidSlideIndex(destinationIndex)
        }
        guard sourceIndex != destinationIndex else { return }
        let moved = slides.remove(at: sourceIndex)
        slides.insert(moved, at: destinationIndex)
        try replaceSlideOrder(slides)
        manifestVersion &+= 1
    }

    func removeSlide(assetID: String) throws {
        var slides = orderedSlides
        guard let index = slides.firstIndex(where: { $0.assetID == assetID }) else {
            throw TourContentStoreError.unknownSlide(assetID)
        }
        slides.remove(at: index)
        assets.removeAll { $0.assetID == assetID }
        sourcesByAssetID.removeValue(forKey: assetID)
        try replaceSlideOrder(slides)
        manifestVersion &+= 1
    }

    func manifestPayload() throws -> TourPackManifestPayload {
        guard let packID else { throw TourContentStoreError.packNotStarted }
        return try TourPackManifestPayload(
            packID: packID,
            manifestVersion: manifestVersion,
            displayName: displayName,
            assets: assets
        )
    }

    private func sourceDirectory(for packID: UUID) -> URL {
        rootDirectory
            .appending(path: packID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "sources", directoryHint: .isDirectory)
    }

    private var orderedSlides: [TourAssetDescriptor] {
        assets.filter { $0.kind == .slide }
            .sorted { ($0.order, $0.assetID) < ($1.order, $1.assetID) }
    }

    private func replaceSlideOrder(_ slides: [TourAssetDescriptor]) throws {
        let slideIDs = Set(slides.map(\.assetID))
        assets.removeAll { $0.kind == .slide && slideIDs.contains($0.assetID) }
        let reordered = try slides.enumerated().map { index, slide in
            try TourAssetDescriptor(
                assetID: slide.assetID,
                kind: slide.kind,
                sha256: slide.sha256,
                byteLength: slide.byteLength,
                order: UInt32(index),
                mimeType: slide.mimeType
            )
        }
        assets.append(contentsOf: reordered)
        nextSlideOrder = UInt32(reordered.count)
    }

    nonisolated private static func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw TourContentStoreError.sourceDirectoryUnavailable(url)
        }
    }

    @concurrent
    private static func persist(data: Data, destination: URL) async throws -> (
        sha256: String,
        byteLength: UInt64
    ) {
        try createDirectory(destination.deletingLastPathComponent())
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (hash, UInt64(data.count))
    }

    @concurrent
    private static func persist(file source: URL, destination: URL) async throws -> (
        sha256: String,
        byteLength: UInt64
    ) {
        try createDirectory(destination.deletingLastPathComponent())
        let temporary = destination.appendingPathExtension("importing")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        try FileManager.default.copyItem(at: source, to: temporary)
        do {
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var hasher = SHA256()
            var byteLength: UInt64 = 0
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
                byteLength += UInt64(chunk.count)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (hash, byteLength)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": "png"
        case "image/heic", "image/heif": "heic"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}
