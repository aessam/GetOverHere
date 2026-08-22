import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Tour asset transfer service", .serialized)
struct TourAssetTransferServiceTests {
    private enum TestTimeout: Error {
        case expired
        case streamEnded
    }

    @Test("Interrupted transfer resumes and reports verified participant readiness")
    @MainActor
    func resumeAndReadiness() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GetOverHereTransferTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary transfer cleanup failed: \(error.localizedDescription)") }
        }

        let sourceURL = root.appending(path: "source.bin", directoryHint: .notDirectory)
        let mapSourceURL = root.appending(path: "tour.pmtiles", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data((0 ..< 150_000).map { UInt8($0 % 251) })
        let mapBytes = Data((0 ..< 80_000).map { UInt8(($0 * 7) % 251) })
        try bytes.write(to: sourceURL, options: .atomic)
        try mapBytes.write(to: mapSourceURL, options: .atomic)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let mapHash = SHA256.hash(data: mapBytes).map { String(format: "%02x", $0) }.joined()
        let asset = try TourAssetDescriptor(
            assetID: "gate-left",
            kind: .slide,
            sha256: hash,
            byteLength: UInt64(bytes.count),
            order: 0,
            mimeType: "image/jpeg"
        )
        let mapAsset = try TourAssetDescriptor(
            assetID: "alhambra-map",
            kind: .mapArchive,
            sha256: mapHash,
            byteLength: UInt64(mapBytes.count),
            order: 1,
            mimeType: "application/vnd.pmtiles"
        )
        let packID = UUID()
        let manifest = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 1,
            displayName: "Alhambra",
            assets: [asset, mapAsset]
        )

        let guideCache = try FileTourAssetCache(
            rootDirectory: root.appending(path: "guide-cache", directoryHint: .isDirectory)
        )
        let guestCache = try FileTourAssetCache(
            rootDirectory: root.appending(path: "guest-cache", directoryHint: .isDirectory)
        )
        let firstChunk = try AssetChunkPayload(
            sha256: hash,
            offset: 0,
            totalLength: UInt64(bytes.count),
            bytes: bytes.prefix(TourAssetTransferService.chunkSize)
        )
        #expect(try await guestCache.ingest(firstChunk) == .partial(
            nextOffset: UInt64(TourAssetTransferService.chunkSize)
        ))

        let guideID = UUID()
        let guestID = UUID()
        let sessionID = UUID()
        let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        let guide = TourAssetTransferService(
            transport: LocalSessionAssetTransport(port: 50_012),
            cache: guideCache
        )
        let guest = TourAssetTransferService(
            transport: LocalSessionAssetTransport(port: 50_012),
            cache: guestCache
        )
        let (guideEvents, guideContinuation) = AsyncStream.makeStream(of: TourAssetTransferEvent.self)
        let (guestEvents, guestContinuation) = AsyncStream.makeStream(of: TourAssetTransferEvent.self)
        guide.setEventHandler { guideContinuation.yield($0) }
        guest.setEventHandler { guestContinuation.yield($0) }
        defer {
            guest.stop()
            guide.stop()
            guideContinuation.finish()
            guestContinuation.finish()
        }

        guide.configureSession(
            sessionID: sessionID,
            participantID: guideID,
            displayName: "Guide",
            platform: .iOS,
            credential: credential
        )
        guest.configureSession(
            sessionID: sessionID,
            participantID: guestID,
            displayName: "Guest",
            platform: .iOS,
            credential: credential
        )
        let emptyManifest = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 0,
            displayName: "Alhambra",
            assets: []
        )
        try await guide.hostTourPack(emptyManifest, sourcesByAssetID: [:])
        guest.joinTour(hostIP: "127.0.0.1")
        _ = try await next(from: guestEvents) {
            if case let .manifestReceived(received) = $0 { received.manifestVersion == 0 } else { false }
        }
        #expect(guide.connectedParticipantIDs == [guestID])

        try await guide.hostTourPack(
            manifest,
            sourcesByAssetID: [
                asset.assetID: sourceURL,
                mapAsset.assetID: mapSourceURL,
            ]
        )

        let guestReady = try await next(from: guestEvents) {
            if case .assetReady(assetID: "gate-left", url: _) = $0 { true } else { false }
        }
        guard case let .assetReady(_, readyURL) = guestReady else {
            Issue.record("Expected verified guest asset")
            return
        }
        #expect(try Data(contentsOf: readyURL) == bytes)

        let guestMapReady = try await next(from: guestEvents) {
            if case .assetReady(assetID: "alhambra-map", url: _) = $0 { true } else { false }
        }
        guard case let .assetReady(_, readyMapURL) = guestMapReady else {
            Issue.record("Expected verified guest map archive")
            return
        }
        #expect(try Data(contentsOf: readyMapURL) == mapBytes)

        let guideReady = try await next(from: guideEvents) {
            if case .participantReady = $0 { true } else { false }
        }
        guard case let .participantReady(readyParticipantID) = guideReady else {
            Issue.record("Expected participant readiness")
            return
        }
        #expect(readyParticipantID == guestID)
        #expect(guide.isParticipantReady(guestID))
        #expect(guide.lastError == nil)
        #expect(guest.lastError == nil)

        guest.stop()
        guest.joinTour(hostIP: "127.0.0.1")
        let readyAfterRejoin = try await next(from: guideEvents) {
            if case .participantReady = $0 { true } else { false }
        }
        guard case let .participantReady(rejoinedParticipantID) = readyAfterRejoin else {
            Issue.record("Expected cached readiness after rejoin")
            return
        }
        #expect(rejoinedParticipantID == guestID)
        #expect(guide.connectedParticipantIDs == [guestID])
        #expect(guide.isParticipantReady(guestID))
        #expect(try Data(contentsOf: readyURL) == bytes)
        #expect(try Data(contentsOf: readyMapURL) == mapBytes)
    }

    private func next(
        from stream: AsyncStream<TourAssetTransferEvent>,
        matching predicate: @escaping @Sendable (TourAssetTransferEvent) -> Bool
    ) async throws -> TourAssetTransferEvent {
        try await withThrowingTaskGroup(of: TourAssetTransferEvent.self) { group in
            group.addTask {
                for await event in stream where predicate(event) { return event }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestTimeout.expired
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }
}
