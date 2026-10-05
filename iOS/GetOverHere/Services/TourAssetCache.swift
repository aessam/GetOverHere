import CryptoKit
import Foundation
import TourSessionCore

enum AssetCacheIngestResult: Equatable, Sendable {
    case partial(nextOffset: UInt64)
    case ready(URL)
}

enum AssetCacheError: LocalizedError, Equatable {
    case invalidHash(String)
    /// Deprecated (DSCN-17, ADR-049): no longer thrown. A length-mismatched complete entry or an
    /// oversized partial is repaired in place (deleted, one stderr line) and reported as missing
    /// (`nil` / offset 0) so the transfer service re-requests it. Kept until a deletion round.
    case lengthMismatch(expected: UInt64, actual: UInt64)
    case offsetMismatch(expected: UInt64, actual: UInt64)
    case checksumMismatch(expected: String, actual: String)
    case createFileFailed(URL)
    case missingFileSize(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidHash(hash): "Invalid lowercase SHA-256: \(hash)"
        case let .lengthMismatch(expected, actual):
            "Asset length mismatch: expected \(expected), got \(actual)"
        case let .offsetMismatch(expected, actual):
            "Asset offset mismatch: expected \(expected), got \(actual)"
        case let .checksumMismatch(expected, actual):
            "Asset checksum mismatch: expected \(expected), got \(actual)"
        case let .createFileFailed(url): "Could not create partial asset at \(url.path)"
        case let .missingFileSize(url): "Could not read asset size at \(url.path)"
        }
    }
}

protocol TourAssetCache: Sendable {
    func readyURL(sha256: String, expectedLength: UInt64) async throws -> URL?
    func resumeOffset(sha256: String, expectedLength: UInt64) async throws -> UInt64
    func ingest(_ chunk: AssetChunkPayload) async throws -> AssetCacheIngestResult
    func discardPartial(sha256: String) async throws
}

final class FileTourAssetCache: TourAssetCache, @unchecked Sendable {
    private let fileManager: FileManager
    private let completeDirectory: URL
    private let partialDirectory: URL
    private let queue = DispatchQueue(label: "com.aens.GetOverHere.asset-cache")

    init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        completeDirectory = rootDirectory.appending(path: "complete", directoryHint: .isDirectory)
        partialDirectory = rootDirectory.appending(path: "partial", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: completeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        // Received tour content is re-fetchable session data, not user data (FND-13): keep it out of backups.
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    func readyURL(sha256: String, expectedLength: UInt64) async throws -> URL? {
        try queue.sync { try readyURLLocked(sha256: sha256, expectedLength: expectedLength) }
    }

    func resumeOffset(sha256: String, expectedLength: UInt64) async throws -> UInt64 {
        try queue.sync {
            if try readyURLLocked(sha256: sha256, expectedLength: expectedLength) != nil {
                return expectedLength
            }
            let partial = try partialURL(sha256: sha256)
            guard fileManager.fileExists(atPath: partial.path) else { return 0 }
            let actual = try fileSize(at: partial)
            guard actual <= expectedLength else {
                try fileManager.removeItem(at: partial)
                fputs("Asset cache: removed oversized partial \(sha256) (expected \(expectedLength), got \(actual))\n", stderr)
                return 0
            }
            return actual
        }
    }

    func ingest(_ chunk: AssetChunkPayload) async throws -> AssetCacheIngestResult {
        try queue.sync { try ingestLocked(chunk) }
    }

    func discardPartial(sha256: String) async throws {
        try queue.sync {
            let url = try partialURL(sha256: sha256)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func readyURLLocked(sha256: String, expectedLength: UInt64) throws -> URL? {
        let url = try completeURL(sha256: sha256)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let actual = try fileSize(at: url)
        guard actual == expectedLength else {
            // Repair locally and report missing; a removeItem failure still throws (loud).
            try fileManager.removeItem(at: url)
            fputs("Asset cache: removed length-mismatched complete entry \(sha256) (expected \(expectedLength), got \(actual))\n", stderr)
            return nil
        }
        return url
    }

    private func ingestLocked(_ chunk: AssetChunkPayload) throws -> AssetCacheIngestResult {
        if let ready = try readyURLLocked(sha256: chunk.sha256, expectedLength: chunk.totalLength) {
            return .ready(ready)
        }

        let partial = try partialURL(sha256: chunk.sha256)
        let currentLength = fileManager.fileExists(atPath: partial.path) ? try fileSize(at: partial) : 0
        guard currentLength == chunk.offset else {
            throw AssetCacheError.offsetMismatch(expected: currentLength, actual: chunk.offset)
        }

        if !fileManager.fileExists(atPath: partial.path),
           !fileManager.createFile(atPath: partial.path, contents: nil) {
            throw AssetCacheError.createFileFailed(partial)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer {
            do { try handle.close() }
            catch { fputs("Asset cache: close failed (\(String(describing: type(of: error))))\n", stderr) }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: chunk.bytes)
        try handle.synchronize()

        let nextOffset = chunk.offset + UInt64(chunk.bytes.count)
        guard nextOffset == chunk.totalLength else { return .partial(nextOffset: nextOffset) }

        let actualHash = try sha256(of: partial)
        guard actualHash == chunk.sha256 else {
            try fileManager.removeItem(at: partial)
            throw AssetCacheError.checksumMismatch(expected: chunk.sha256, actual: actualHash)
        }

        let complete = try completeURL(sha256: chunk.sha256)
        if fileManager.fileExists(atPath: complete.path) {
            try fileManager.removeItem(at: complete)
        }
        try fileManager.moveItem(at: partial, to: complete)
        return .ready(complete)
    }

    private func completeURL(sha256: String) throws -> URL {
        try validate(sha256)
        return completeDirectory.appending(path: sha256, directoryHint: .notDirectory)
    }

    private func partialURL(sha256: String) throws -> URL {
        try validate(sha256)
        return partialDirectory.appending(path: "\(sha256).part", directoryHint: .notDirectory)
    }

    private func validate(_ sha256: String) throws {
        guard sha256.count == 64,
              sha256 == sha256.lowercased(),
              sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw AssetCacheError.invalidHash(sha256)
        }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw AssetCacheError.missingFileSize(url)
        }
        return size.uint64Value
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { fputs("Asset cache: close failed (\(String(describing: type(of: error))))\n", stderr) }
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
