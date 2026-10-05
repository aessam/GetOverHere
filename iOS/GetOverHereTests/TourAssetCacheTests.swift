import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Content-addressed tour asset cache")
struct TourAssetCacheTests {
    @Test("Transfer resumes, verifies SHA-256, and rejects corruption")
    func resumeVerifyAndRejectCorruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereAssetCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary asset cleanup failed: \(error.localizedDescription)") }
        }

        let bytes = Data("offline-tour-asset".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let firstCount = 7
        let first = try AssetChunkPayload(
            sha256: hash,
            offset: 0,
            totalLength: UInt64(bytes.count),
            bytes: bytes.prefix(firstCount)
        )
        let firstCache = try FileTourAssetCache(rootDirectory: root)
        #expect(try await firstCache.ingest(first) == .partial(nextOffset: UInt64(firstCount)))

        let resumedCache = try FileTourAssetCache(rootDirectory: root)
        #expect(try await resumedCache.resumeOffset(
            sha256: hash,
            expectedLength: UInt64(bytes.count)
        ) == UInt64(firstCount))
        let final = try AssetChunkPayload(
            sha256: hash,
            offset: UInt64(firstCount),
            totalLength: UInt64(bytes.count),
            bytes: bytes.dropFirst(firstCount)
        )
        guard case let .ready(url) = try await resumedCache.ingest(final) else {
            Issue.record("Expected a verified complete asset")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await resumedCache.readyURL(
            sha256: hash,
            expectedLength: UInt64(bytes.count)
        ) == url)

        let corruptRoot = root.appending(path: "corrupt", directoryHint: .isDirectory)
        let corruptCache = try FileTourAssetCache(rootDirectory: corruptRoot)
        let corrupt = try AssetChunkPayload(
            sha256: hash,
            offset: 0,
            totalLength: UInt64(bytes.count),
            bytes: Data(repeating: 0xff, count: bytes.count)
        )
        do {
            _ = try await corruptCache.ingest(corrupt)
            Issue.record("Corrupt asset was accepted")
        } catch let error as AssetCacheError {
            guard case .checksumMismatch = error else {
                Issue.record("Expected checksum mismatch, got \(error)")
                return
            }
        }
        #expect(try await corruptCache.resumeOffset(
            sha256: hash,
            expectedLength: UInt64(bytes.count)
        ) == 0)
    }

    @Test("A length-mismatched complete entry is deleted and reported missing")
    @MainActor
    func lengthMismatchedCompleteEntryIsDeletedAndReportedMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereAssetCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary asset cleanup failed: \(error.localizedDescription)") }
        }

        let bytes = Data("offline-tour-asset".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let cache = try FileTourAssetCache(rootDirectory: root)
        let corruptComplete = root
            .appending(path: "complete", directoryHint: .isDirectory)
            .appending(path: hash, directoryHint: .notDirectory)
        try Data(repeating: 0, count: 10).write(to: corruptComplete, options: .atomic)

        #expect(try await cache.readyURL(sha256: hash, expectedLength: UInt64(bytes.count)) == nil)
        #expect(!FileManager.default.fileExists(atPath: corruptComplete.path), "corrupt entry must be removed")
        #expect(try await cache.resumeOffset(sha256: hash, expectedLength: UInt64(bytes.count)) == 0)

        let full = try AssetChunkPayload(
            sha256: hash,
            offset: 0,
            totalLength: UInt64(bytes.count),
            bytes: bytes
        )
        guard case let .ready(url) = try await cache.ingest(full) else {
            Issue.record("Expected a verified complete asset after the repair")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await cache.readyURL(sha256: hash, expectedLength: UInt64(bytes.count)) == url)
    }

    @Test("An oversized partial is deleted and resume restarts at zero")
    @MainActor
    func oversizedPartialIsDeletedAndResumeRestartsAtZero() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereAssetCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary asset cleanup failed: \(error.localizedDescription)") }
        }

        let bytes = Data("offline-tour-asset".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let cache = try FileTourAssetCache(rootDirectory: root)
        let oversizedPartial = root
            .appending(path: "partial", directoryHint: .isDirectory)
            .appending(path: "\(hash).part", directoryHint: .notDirectory)
        try Data(repeating: 0, count: 30).write(to: oversizedPartial, options: .atomic)

        #expect(try await cache.resumeOffset(sha256: hash, expectedLength: UInt64(bytes.count)) == 0)
        #expect(!FileManager.default.fileExists(atPath: oversizedPartial.path), "oversized partial must be removed")
    }
}
