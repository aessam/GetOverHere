import CryptoKit
import Foundation

public enum TourPackError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt8)
    case reservedBitsSet
    case invalidManifestLength(Int)
    case invalidEntryCount(Int)
    case truncated
    case indexNotSorted
    case offsetMismatch(index: Int)
    case manifestIndexMismatch
    case inconsistentLength(sha256: String)
    case entryTooLarge(sha256: String)
    case packTooLarge(UInt64)
    case fileLengthMismatch(expected: UInt64, actual: UInt64)
    case trailerMismatch
    case assetHashMismatch(sha256: String)
    case missingAsset(sha256: String)
}

/// `.gohtour` container, GOHP v1 (ADR-080, TourPackFormat.md). Big-endian like GOH2:
///
///     header 16: "GOHP" | version | flags | reserved u16 | manifestLength u32 | entryCount u32
///     manifest:  TourPackManifestPayload.encode(), unchanged
///     index:     entryCount × (sha256 32 | byteLength u64 | offset u64), sorted by raw SHA-256, unique
///     data:      asset bytes in index order, contiguous
///     trailer:   SHA-256 of every preceding byte
///
/// A pack is untrusted input. Its files are used only when the live session's authenticated manifest
/// names their hash, so a forged pack can only add unused cache entries.
public enum TourPackArchive {
    public static let magic = Data("GOHP".utf8)
    public static let version: UInt8 = 1
    public static let headerLength = 16
    public static let indexEntryLength = 48
    public static let trailerLength = 32
    public static let maximumManifestLength = 1 << 20
    public static let maximumEntryCount = 4_096
    public static let maximumEntryLength: UInt64 = 512 << 20
    public static let maximumTotalLength: UInt64 = 2 << 30

    public struct Entry: Equatable, Sendable {
        /// Raw 32-byte digest; `sha256Hex` matches `TourAssetDescriptor.sha256`.
        public let sha256: Data
        public let byteLength: UInt64
        public let offset: UInt64
        public var sha256Hex: String { sha256.lowercaseHex }
    }

    public struct Layout: Equatable, Sendable {
        public let manifest: TourPackManifestPayload
        public let entries: [Entry]
        /// Length of header + manifest + index; the first asset starts here.
        public let dataOffset: UInt64
        /// Whole file length including the trailer.
        public let totalLength: UInt64
    }

    /// The header, manifest and index for `manifest`, and where each asset will sit. Writers stream the
    /// asset bytes after this prefix in `entries` order and finish with `trailer(of:)`.
    public static func prefix(for manifest: TourPackManifestPayload) throws -> (bytes: Data, layout: Layout) {
        var lengths = [String: UInt64]()
        for asset in manifest.assets {
            if let known = lengths[asset.sha256], known != asset.byteLength {
                throw TourPackError.inconsistentLength(sha256: asset.sha256)
            }
            guard asset.byteLength <= maximumEntryLength else { throw TourPackError.entryTooLarge(sha256: asset.sha256) }
            lengths[asset.sha256] = asset.byteLength
        }
        // Lowercase hex sorts exactly like the raw digest bytes.
        let hashes = lengths.keys.sorted()
        guard (1 ... maximumEntryCount).contains(hashes.count) else { throw TourPackError.invalidEntryCount(hashes.count) }
        let manifestBytes = try manifest.encode()
        guard (1 ... maximumManifestLength).contains(manifestBytes.count) else {
            throw TourPackError.invalidManifestLength(manifestBytes.count)
        }
        let dataOffset = UInt64(headerLength + manifestBytes.count + hashes.count * indexEntryLength)
        var offset = dataOffset
        var entries = [Entry]()
        entries.reserveCapacity(hashes.count)
        for hash in hashes {
            let length = lengths[hash]!
            entries.append(Entry(sha256: try Data(hex: hash), byteLength: length, offset: offset))
            offset += length
        }
        let totalLength = offset + UInt64(trailerLength)
        guard totalLength <= maximumTotalLength else { throw TourPackError.packTooLarge(totalLength) }

        var writer = BinaryWriter(capacity: Int(dataOffset))
        writer.append(magic)
        writer.append(version)
        writer.append(UInt8(0))
        writer.append(UInt16(0))
        writer.append(UInt32(manifestBytes.count))
        writer.append(UInt32(entries.count))
        writer.append(manifestBytes)
        for entry in entries {
            writer.append(entry.sha256)
            writer.append(entry.byteLength)
            writer.append(entry.offset)
        }
        return (writer.data, Layout(manifest: manifest, entries: entries, dataOffset: dataOffset, totalLength: totalLength))
    }

    /// The whole-file trailer: SHA-256 of header, manifest, index and data.
    public static func trailer(of bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }

    /// In-memory writer for fixtures and small packs. `assets` maps lowercase SHA-256 hex to bytes.
    public static func write(manifest: TourPackManifestPayload, assets: [String: Data]) throws -> Data {
        let (prefix, layout) = try prefix(for: manifest)
        var file = prefix
        for entry in layout.entries {
            let hash = entry.sha256Hex
            guard let bytes = assets[hash] else { throw TourPackError.missingAsset(sha256: hash) }
            guard UInt64(bytes.count) == entry.byteLength, Data(SHA256.hash(data: bytes)) == entry.sha256 else {
                throw TourPackError.assetHashMismatch(sha256: hash)
            }
            file.append(bytes)
        }
        file.append(trailer(of: file))
        return file
    }

    /// Bytes an importer must read before `parsePrefix`: header, manifest and index.
    public static func prefixLength(header: Data) throws -> Int {
        let (manifestLength, entryCount) = try parseHeader(header)
        return headerLength + manifestLength + entryCount * indexEntryLength
    }

    /// Validates everything except the asset hashes and the trailer, which need the data bytes.
    public static func parsePrefix(_ prefix: Data, fileLength: UInt64) throws -> Layout {
        let (manifestLength, entryCount) = try parseHeader(prefix)
        let dataOffset = headerLength + manifestLength + entryCount * indexEntryLength
        guard prefix.count >= dataOffset else { throw TourPackError.truncated }
        var reader = BinaryReader(data: prefix.subdata(in: prefix.startIndex + headerLength ..< prefix.startIndex + dataOffset))
        let manifest = try TourPackManifestPayload.decode(try reader.readData(count: manifestLength))

        var entries = [Entry]()
        entries.reserveCapacity(entryCount)
        var expectedOffset = UInt64(dataOffset)
        for index in 0 ..< entryCount {
            let entry = Entry(sha256: try reader.readData(count: 32), byteLength: try reader.readUInt64(), offset: try reader.readUInt64())
            if let previous = entries.last, !previous.sha256.lexicographicallyPrecedes(entry.sha256) {
                throw TourPackError.indexNotSorted
            }
            guard entry.byteLength <= maximumEntryLength else { throw TourPackError.entryTooLarge(sha256: entry.sha256Hex) }
            guard entry.offset == expectedOffset else { throw TourPackError.offsetMismatch(index: index) }
            expectedOffset += entry.byteLength
            entries.append(entry)
        }

        var manifestLengths = [String: UInt64]()
        for asset in manifest.assets {
            if let known = manifestLengths[asset.sha256], known != asset.byteLength {
                throw TourPackError.inconsistentLength(sha256: asset.sha256)
            }
            manifestLengths[asset.sha256] = asset.byteLength
        }
        guard Set(manifestLengths.keys) == Set(entries.map(\.sha256Hex)) else { throw TourPackError.manifestIndexMismatch }
        for entry in entries where manifestLengths[entry.sha256Hex] != entry.byteLength {
            throw TourPackError.inconsistentLength(sha256: entry.sha256Hex)
        }

        let totalLength = expectedOffset + UInt64(trailerLength)
        guard totalLength <= maximumTotalLength else { throw TourPackError.packTooLarge(totalLength) }
        guard totalLength == fileLength else { throw TourPackError.fileLengthMismatch(expected: totalLength, actual: fileLength) }
        return Layout(manifest: manifest, entries: entries, dataOffset: UInt64(dataOffset), totalLength: totalLength)
    }

    /// In-memory reader for fixtures and small packs: full validation, including every asset hash and
    /// the trailer. Returns the layout and the assets keyed by lowercase SHA-256 hex.
    public static func read(_ file: Data) throws -> (layout: Layout, assets: [String: Data]) {
        let file = Data(file)
        let layout = try parsePrefix(file, fileLength: UInt64(file.count))
        let body = file.prefix(file.count - trailerLength)
        guard trailer(of: body) == file.suffix(trailerLength) else { throw TourPackError.trailerMismatch }
        var assets = [String: Data]()
        for entry in layout.entries {
            let bytes = file.subdata(in: Int(entry.offset) ..< Int(entry.offset + entry.byteLength))
            guard Data(SHA256.hash(data: bytes)) == entry.sha256 else {
                throw TourPackError.assetHashMismatch(sha256: entry.sha256Hex)
            }
            assets[entry.sha256Hex] = bytes
        }
        return (layout, assets)
    }

    private static func parseHeader(_ data: Data) throws -> (manifestLength: Int, entryCount: Int) {
        guard data.count >= headerLength else { throw TourPackError.truncated }
        var reader = BinaryReader(data: Data(data.prefix(headerLength)))
        guard try reader.readData(count: 4) == magic else { throw TourPackError.badMagic }
        let fileVersion = try reader.readUInt8()
        guard fileVersion == version else { throw TourPackError.unsupportedVersion(fileVersion) }
        guard try reader.readUInt8() == 0, try reader.readUInt16() == 0 else { throw TourPackError.reservedBitsSet }
        let manifestLength = Int(try reader.readUInt32())
        guard (1 ... maximumManifestLength).contains(manifestLength) else { throw TourPackError.invalidManifestLength(manifestLength) }
        let entryCount = Int(try reader.readUInt32())
        guard (1 ... maximumEntryCount).contains(entryCount) else { throw TourPackError.invalidEntryCount(entryCount) }
        return (manifestLength, entryCount)
    }
}
