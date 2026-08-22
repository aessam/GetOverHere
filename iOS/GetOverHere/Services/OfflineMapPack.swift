import Foundation
import TourSessionCore

struct OfflineMapConfiguration: Equatable, Sendable {
    let styleJSON: String
    let archiveURL: URL
}

enum OfflineMapPackError: LocalizedError {
    case missingStyle
    case missingArchive
    case styleNotReady
    case archiveNotReady
    case invalidStyle(String)
    case invalidArchive
    case remoteResource(String)

    var errorDescription: String? {
        switch self {
        case .missingStyle: "The tour pack has no map style"
        case .missingArchive: "The tour pack has no PMTiles archive"
        case .styleNotReady: "The offline map style is not ready"
        case .archiveNotReady: "The offline map archive is not ready"
        case let .invalidStyle(reason): "Invalid offline map style: \(reason)"
        case .invalidArchive: "The selected archive is not a PMTiles v3 file"
        case let .remoteResource(url): "Offline map style references a network resource: \(url)"
        }
    }
}

enum OfflineMapPack {
    static let archivePlaceholder = "getoverhere://map-archive"
    static let maximumStyleBytes = 2 * 1_024 * 1_024
    private static let pmTilesHeaderByteCount = 127
    private static let maximumRootDirectoryEnd = 16_384

    static func resolve(
        manifest: TourPackManifestPayload,
        filesByAssetID: [String: URL]
    ) throws -> OfflineMapConfiguration {
        guard let style = manifest.assets.first(where: { $0.kind == .mapStyle }) else {
            throw OfflineMapPackError.missingStyle
        }
        guard let archive = manifest.assets.first(where: { $0.kind == .mapArchive }) else {
            throw OfflineMapPackError.missingArchive
        }
        guard let styleURL = filesByAssetID[style.assetID] else {
            throw OfflineMapPackError.styleNotReady
        }
        guard let archiveURL = filesByAssetID[archive.assetID] else {
            throw OfflineMapPackError.archiveNotReady
        }
        try validateArchive(at: archiveURL)
        let styleData = try Data(contentsOf: styleURL, options: [.mappedIfSafe])
        return try configuration(styleData: styleData, archiveURL: archiveURL)
    }

    static func configuration(styleData: Data, archiveURL: URL) throws -> OfflineMapConfiguration {
        guard styleData.count <= maximumStyleBytes else {
            throw OfflineMapPackError.invalidStyle("style exceeds 2 MiB")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: styleData)
        } catch {
            throw OfflineMapPackError.invalidStyle(error.localizedDescription)
        }
        guard var root = value as? [String: Any], root["version"] as? Int == 8 else {
            throw OfflineMapPackError.invalidStyle("root must be a MapLibre style version 8 object")
        }
        guard var sources = root["sources"] as? [String: Any], !sources.isEmpty else {
            throw OfflineMapPackError.invalidStyle("sources must not be empty")
        }

        try rejectRemoteResource(root["glyphs"])
        try rejectRemoteResource(root["sprite"])

        var replacementCount = 0
        for (sourceID, sourceValue) in sources {
            guard var source = sourceValue as? [String: Any] else {
                throw OfflineMapPackError.invalidStyle("source \(sourceID) must be an object")
            }
            if let url = source["url"] as? String {
                if url == archivePlaceholder {
                    source["url"] = "pmtiles://\(archiveURL.absoluteString)"
                    replacementCount += 1
                } else {
                    try rejectRemoteResource(url)
                }
            }
            if let tiles = source["tiles"] as? [String] {
                for tile in tiles { try rejectRemoteResource(tile) }
            }
            sources[sourceID] = source
        }
        guard replacementCount == 1 else {
            throw OfflineMapPackError.invalidStyle(
                "exactly one source URL must equal \(archivePlaceholder)"
            )
        }
        root["sources"] = sources

        let resolvedData: Data
        do {
            resolvedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        } catch {
            throw OfflineMapPackError.invalidStyle(error.localizedDescription)
        }
        guard let styleJSON = String(data: resolvedData, encoding: .utf8) else {
            throw OfflineMapPackError.invalidStyle("style is not UTF-8")
        }
        return OfflineMapConfiguration(styleJSON: styleJSON, archiveURL: archiveURL)
    }

    static func validateArchive(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: pmTilesHeaderByteCount) ?? Data()
        guard fileSize >= pmTilesHeaderByteCount,
              header.count == pmTilesHeaderByteCount,
              header.prefix(8) == Data([0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73, 0x03]) else {
            throw OfflineMapPackError.invalidArchive
        }

        let rootOffset = readUInt64LE(header, at: 8)
        let rootLength = readUInt64LE(header, at: 16)
        let metadataOffset = readUInt64LE(header, at: 24)
        let metadataLength = readUInt64LE(header, at: 32)
        let leafOffset = readUInt64LE(header, at: 40)
        let leafLength = readUInt64LE(header, at: 48)
        let tileOffset = readUInt64LE(header, at: 56)
        let tileLength = readUInt64LE(header, at: 64)
        let addressedTiles = readUInt64LE(header, at: 72)
        let tileEntries = readUInt64LE(header, at: 80)
        let tileContents = readUInt64LE(header, at: 88)
        guard rootLength > 0,
              metadataLength > 0,
              tileLength > 0,
              addressedTiles > 0,
              tileEntries > 0,
              tileContents > 0,
              section(offset: rootOffset, length: rootLength, fitsWithin: fileSize),
              section(offset: metadataOffset, length: metadataLength, fitsWithin: fileSize),
              section(offset: leafOffset, length: leafLength, fitsWithin: fileSize),
              section(offset: tileOffset, length: tileLength, fitsWithin: fileSize),
              rootOffset >= UInt64(pmTilesHeaderByteCount),
              rootOffset + rootLength <= UInt64(maximumRootDirectoryEnd),
              (1 ... 4).contains(header[97]),
              (1 ... 4).contains(header[98]),
              (1 ... 6).contains(header[99]),
              header[100] <= header[101] else {
            throw OfflineMapPackError.invalidArchive
        }
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        data[offset ..< offset + 8].enumerated().reduce(UInt64(0)) { value, element in
            value | (UInt64(element.element) << UInt64(element.offset * 8))
        }
    }

    private static func section(offset: UInt64, length: UInt64, fitsWithin fileSize: UInt64) -> Bool {
        guard offset <= fileSize else { return false }
        return length <= fileSize - offset
    }

    private static func rejectRemoteResource(_ value: Any?) throws {
        guard let url = value as? String else { return }
        let lowercased = url.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            throw OfflineMapPackError.remoteResource(url)
        }
    }
}
