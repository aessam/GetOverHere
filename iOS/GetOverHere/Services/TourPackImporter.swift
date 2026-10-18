import CryptoKit
import Foundation
import TourSessionCore

/// Imports a `.gohtour` pack (ADR-080, TourPackFormat.md) into the hash-keyed asset cache.
///
/// The pack is untrusted. The prefix (header, manifest, index) and the whole-file trailer are
/// validated before any asset is written; each asset then goes through the cache's normal chunk
/// path, which checks its SHA-256 on completion. Cached files are used only when the live
/// session's authenticated manifest names their hash.
struct TourPackImporter {
    struct Outcome: Equatable {
        let manifest: TourPackManifestPayload
        let imported: Int
        let alreadyCached: Int
    }

    let cache: any TourAssetCache
    var chunkSize = TourAssetTransferService.chunkSize

    func importPack(at url: URL) async throws -> Outcome {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() } catch {
                fputs("Tour pack: close failed (\(String(describing: type(of: error))))\n", stderr)
            }
        }
        let fileLength = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        let header = try read(handle, TourPackArchive.headerLength)
        let prefixLength = try TourPackArchive.prefixLength(header: header)
        let prefix = header + (try read(handle, prefixLength - TourPackArchive.headerLength))
        let layout = try TourPackArchive.parsePrefix(prefix, fileLength: fileLength)

        // Pass 1: the trailer covers every byte, so nothing is written from a truncated or altered file.
        var hasher = SHA256()
        hasher.update(data: prefix)
        var remaining = layout.totalLength - layout.dataOffset - UInt64(TourPackArchive.trailerLength)
        while remaining > 0 {
            let count = Int(min(UInt64(chunkSize), remaining))
            hasher.update(data: try read(handle, count))
            remaining -= UInt64(count)
        }
        guard Data(hasher.finalize()) == (try read(handle, TourPackArchive.trailerLength)) else {
            throw TourPackError.trailerMismatch
        }

        // Pass 2: each asset through the cache's chunk path (it re-checks the SHA-256 at completion, which
        // also covers the file changing between the passes).
        var imported = 0
        var alreadyCached = 0
        for entry in layout.entries {
            let hash = entry.sha256Hex
            if try await cache.readyURL(sha256: hash, expectedLength: entry.byteLength) != nil {
                alreadyCached += 1
                continue
            }
            // A partial left by an earlier over-the-air transfer would not start at offset 0.
            try await cache.discardPartial(sha256: hash)
            try handle.seek(toOffset: entry.offset)
            var offset: UInt64 = 0
            var result: AssetCacheIngestResult
            repeat {
                let count = Int(min(UInt64(chunkSize), entry.byteLength - offset))
                let chunk = try AssetChunkPayload(sha256: hash, offset: offset, totalLength: entry.byteLength,
                                                  bytes: try read(handle, count))
                result = try await cache.ingest(chunk)
                offset += UInt64(count)
            } while offset < entry.byteLength
            guard case .ready = result else { throw TourPackError.assetHashMismatch(sha256: hash) }
            imported += 1
        }
        return Outcome(manifest: layout.manifest, imported: imported, alreadyCached: alreadyCached)
    }

    private func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard let data = try handle.read(upToCount: count), data.count == count else { throw TourPackError.truncated }
        return data
    }
}
