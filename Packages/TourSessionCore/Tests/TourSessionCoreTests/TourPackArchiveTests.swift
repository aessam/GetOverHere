import CryptoKit
import Foundation
import Testing
@testable import TourSessionCore

@Suite("Tour pack container GOHP v1 (ADR-080)")
struct TourPackArchiveTests {
    /// Pinned on both platforms (TourPackArchiveTest.kt); any byte change is a format break.
    static let packHex = "474f48500100000000000137000000036f1c5c6a0000400080000000000000a10000000000000003000c4669787475726520546f757200040007736c6964652d310100f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609000000000000000d00000000000a696d6167652f6a7065670007736c6964652d3201aa5cd9acfab25f643fb1cedb67f8770417ac9ce0b02cfe72a62fa1ec20e9f60a0000000000000005000000010009696d6167652f706e670007736c6964652d330100f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609000000000000000d00000002000a696d6167652f6a70656700096d61702d7374796c65039e7feab6660f23cb63046272f63f9bf3dd2a83f92d5af0962878464a8c038783000000000000000d0000000300106170706c69636174696f6e2f6a736f6e00f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609000000000000000d00000000000001d79e7feab6660f23cb63046272f63f9bf3dd2a83f92d5af0962878464a8c038783000000000000000d00000000000001e4aa5cd9acfab25f643fb1cedb67f8770417ac9ce0b02cfe72a62fa1ec20e9f60a000000000000000500000000000001f1474f4820736c696465206f6e657b2276657273696f6e223a387d000102fffee2ee223a7a0ece6175060f972ffc9fee61f5402f184741a09f0e47a748956c99"

    private func fixture() throws -> Data { try Data(hex: Self.packHex) }

    private func mutated(_ change: (inout [UInt8]) -> Void) throws -> Data {
        var bytes = [UInt8](try fixture())
        change(&bytes)
        return Data(bytes)
    }

    @Test("The fixture writer output is pinned and reads back every asset")
    func pinnedRoundtrip() throws {
        #expect(try TourSessionFixtures.tourPackFixture().lowercaseHex == Self.packHex)
        let (layout, assets) = try TourPackArchive.read(try fixture())
        #expect(layout.manifest.assets.count == 4)
        #expect(layout.entries.count == 3, "two slides share bytes, stored once")
        #expect(layout.dataOffset == 471 && layout.totalLength == 534)
        let expected = Dictionary(uniqueKeysWithValues: TourSessionFixtures.tourPackFixtureAssets().map {
            (Data(SHA256.hash(data: $0)).lowercaseHex, $0)
        })
        #expect(assets == expected)
    }

    @Test("A streaming importer validates the prefix before reading any asset bytes")
    func streamingPrefix() throws {
        let file = try fixture()
        let prefixLength = try TourPackArchive.prefixLength(header: file.prefix(TourPackArchive.headerLength))
        #expect(prefixLength == 471)
        let layout = try TourPackArchive.parsePrefix(file.prefix(prefixLength), fileLength: UInt64(file.count))
        #expect(layout == (try TourPackArchive.read(file)).layout)
    }

    @Test("Malformed packs are rejected before anything is trusted")
    func rejections() throws {
        func error(_ file: Data) -> TourPackError? {
            do { _ = try TourPackArchive.read(file); return nil } catch let error as TourPackError { return error } catch { return nil }
        }
        #expect(error(try mutated { $0[0] = 0x58 }) == .badMagic)
        #expect(error(try mutated { $0[4] = 2 }) == .unsupportedVersion(2))
        #expect(error(try mutated { $0[5] = 1 }) == .reservedBitsSet)
        #expect(error(try fixture().dropLast()) == .fileLengthMismatch(expected: 534, actual: 533))
        #expect(error(try mutated { $0[533] ^= 0x01 }) == .trailerMismatch)
        // Index starts at 16 + 311. Swapping whole entries breaks offsets first; swapping only the hashes of
        // entries 0 and 1 (both 13 bytes long) leaves offsets valid and breaks the sort order.
        #expect(error(try mutated { bytes in
            let first = Array(bytes[327 ..< 375]); bytes[327 ..< 375] = bytes[375 ..< 423]; bytes[375 ..< 423] = first[...]
        }) == .offsetMismatch(index: 0))
        #expect(error(try mutated { bytes in
            let first = Array(bytes[327 ..< 359]); bytes[327 ..< 359] = bytes[375 ..< 407]; bytes[375 ..< 407] = first[...]
        }) == .indexNotSorted)
        // Change the last index hash's final byte: still sorted, but no longer the manifest's set.
        #expect(error(try mutated { $0[454] ^= 0x01 }) == .manifestIndexMismatch)
        // Flip a data byte and re-seal the trailer: only the per-asset hash catches it.
        let resealed = try mutated { bytes in
            bytes[471] ^= 0x01
            let digest = [UInt8](TourPackArchive.trailer(of: Data(bytes[0 ..< 502])))
            bytes.replaceSubrange(502 ..< 534, with: digest)
        }
        #expect(error(resealed) == .assetHashMismatch(sha256: "00f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609"))
    }

    @Test("The writer refuses missing assets and inconsistent manifest lengths")
    func writerRejections() throws {
        let (layout, _) = try TourPackArchive.read(try fixture())
        #expect(throws: TourPackError.missingAsset(sha256: layout.entries[0].sha256Hex)) {
            try TourPackArchive.write(manifest: layout.manifest, assets: [:])
        }
        let hash = layout.entries[0].sha256Hex
        let conflicting = try TourPackManifestPayload(packID: UUID(), manifestVersion: 1, displayName: "x", assets: [
            TourAssetDescriptor(assetID: "a", kind: .slide, sha256: hash, byteLength: 13, order: 0, mimeType: "image/jpeg"),
            TourAssetDescriptor(assetID: "b", kind: .slide, sha256: hash, byteLength: 14, order: 1, mimeType: "image/jpeg"),
        ])
        #expect(throws: TourPackError.inconsistentLength(sha256: hash)) { try TourPackArchive.prefix(for: conflicting) }
    }
}
