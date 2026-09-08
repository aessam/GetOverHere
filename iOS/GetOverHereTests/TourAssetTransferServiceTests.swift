import CryptoKit
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite("Tour asset transfer service", .serialized)
struct TourAssetTransferServiceTests {
    private enum TestTimeout: Error {
        case expired(String)
        case streamEnded
    }

    @Test("Guide disk work is serial, deduplicated, member-bounded, and fairly paced")
    @MainActor
    func guideQueueIsSerialBoundedAndFair() async throws {
        let f = try await GuideFixture()
        defer { f.close() }
        let first = UUID(), second = UUID()
        f.join(first); f.join(second)
        try await waitUntil("guide members") { f.service.connectedParticipantIDs.count == 2 }
        try f.request(first, assetID: "a")
        try await waitUntil("first blocked read") { f.reader.readCount == 1 }
        try f.request(first, assetID: "a") // exact in-flight duplicate does not reserve another slot
        try f.request(first, assetID: "b")
        try f.request(first, assetID: "a", offset: 1) // third outstanding request is rejected
        try f.request(second, assetID: "a")
        try await waitUntil("bounded queue rejection") { f.service.lastError != nil }
        #expect(f.reader.readCount == 1)
        try f.reader.releaseNext()
        try await waitUntil("second member read") { f.reader.readCount == 2 }
        #expect(f.chunks.map(\.memberID) == [first])
        try f.reader.releaseNext()
        try await waitUntil("first member next read") { f.reader.readCount == 3 }
        #expect(f.chunks.map(\.memberID) == [first, second])
        try f.reader.releaseNext()
        try await waitUntil("all queued chunks") { f.chunks.count == 3 }
        #expect(f.chunks.map(\.memberID) == [first, second, first])
        #expect(f.chunks.map { $0.payload.sha256 } == [f.hash("a"), f.hash("a"), f.hash("b")])
        #expect(f.reader.maximumPending == 1)
        #expect(f.chunks.allSatisfy { $0.payload.bytes.count == TourAssetTransferService.chunkSize })
    }

    @Test("Suspended guide reads cannot escape stop, member replacement, or pack replacement",
          arguments: ["stop", "member", "manifest"])
    @MainActor
    func staleGuideReadNeverSendsIntoReplacement(change: String) async throws {
        let f = try await GuideFixture()
        defer { f.close() }
        let member = UUID()
        f.join(member)
        try await waitUntil("guide member") { f.service.connectedParticipantIDs.contains(member) }
        try f.request(member, assetID: "a")
        try await waitUntil("old blocked read") { f.reader.readCount == 1 }
        switch change {
        case "stop": f.service.stop()
        case "member":
            f.transport.emit(.guestDisconnected(participantID: member))
            f.join(member)
            try await waitUntil("replacement manifest") { f.transport.sent.filter { $0.kind == .tourPackManifest }.count == 2 }
        default:
            try await f.replaceManifest()
        }
        if change != "stop" {
            try f.request(member, assetID: "a", offset: UInt64(TourAssetTransferService.chunkSize))
            for _ in 0..<50 { await Task.yield() }
            #expect(f.reader.readCount == 1, "replacing a generation must not overlap its suspended disk read")
        }
        try f.reader.releaseNext()
        if change == "stop" {
            for _ in 0..<100 { await Task.yield() }
            #expect(f.chunks.isEmpty)
        } else {
            try await waitUntil("replacement read") { f.reader.readCount == 2 }
            #expect(f.chunks.isEmpty, "the old generation must not send")
            try f.reader.releaseNext()
            try await waitUntil("replacement chunk") { f.chunks.count == 1 }
            #expect(f.chunks[0].payload.offset == UInt64(TourAssetTransferService.chunkSize))
            #expect(f.chunks[0].payload.bytes == Data(f.bytes("a").dropFirst(TourAssetTransferService.chunkSize)))
        }
        #expect(f.reader.maximumPending == 1)
    }

    @Test("Unconnected members cannot mark the guide's pack ready")
    @MainActor
    func guideRejectsStatusFromDisconnectedMember() async throws {
        let f = try await GuideFixture()
        defer { f.close() }
        let status = try AssetStatusPayload(sha256: f.hash("a"), status: .ready,
            byteLength: UInt64(f.bytes("a").count), detail: "")
        try f.deliver(member: UUID(), kind: .assetStatus, payload: status.encode())
        try await waitUntil("unknown member status rejection") { f.service.lastError != nil }
        #expect(f.service.readyParticipantIDs.isEmpty)
    }

    @Test("Replacing the same member resets its readiness even without a disconnect event")
    @MainActor
    func sameMemberReplacementRequiresFreshAssetReadiness() async throws {
        let f = try await GuideFixture()
        defer { f.close() }
        let member = UUID()
        func ready(_ assetID: String) throws {
            let payload = try AssetStatusPayload(sha256: f.hash(assetID), status: .ready,
                byteLength: UInt64(f.bytes(assetID).count), detail: "")
            try f.deliver(member: member, kind: .assetStatus, payload: payload.encode())
        }
        f.join(member)
        try await waitUntil("first member") { f.service.connectedParticipantIDs.contains(member) }
        try ready("a"); try ready("b")
        try await waitUntil("first ready report") { f.service.readyParticipantIDs.contains(member) }
        f.join(member)
        try await waitUntil("replacement manifest") { f.transport.sent.filter { $0.kind == .tourPackManifest }.count == 2 }
        #expect(!f.service.readyParticipantIDs.contains(member))
        try ready("b")
        for _ in 0..<100 { await Task.yield() }
        #expect(!f.service.readyParticipantIDs.contains(member), "old hash readiness must not survive member replacement")
        try ready("a")
        try await waitUntil("replacement ready report") { f.service.readyParticipantIDs.contains(member) }
    }

    @Test("Current and next slide take the first two slots even when snapshot precedes manifest")
    @MainActor
    func currentSlidePriorityPrecedesManifest() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000, "b": 1_000, "c": 1_000, "d": 1_000])
        defer { f.close() }
        f.service.prioritizeSlide(assetID: "c")
        try f.deliverManifest()
        try await f.waitForRequestCount(2)
        #expect(f.requests.map(\.sha256) == [f.hash("c"), f.hash("d")])
    }

    @Test("A new slide preempts background work only at a consumed chunk boundary and resumes exact offsets")
    @MainActor
    func slidePriorityYieldsBackgroundChunksWithoutLosingResume() async throws {
        let f = try GuestFixture(sizes: ["a": 70_000, "b": 70_000, "c": 70_000, "d": 1_000])
        defer { f.close() }
        try f.deliverManifest()
        try await f.waitForRequestCount(2)
        f.service.prioritizeSlide(assetID: "c")
        try f.deliverChunk(for: "a", offset: 0)
        try await f.waitForRequestCount(3)
        #expect(f.requests[2].sha256 == f.hash("c"))
        try f.deliverChunk(for: "b", offset: 0)
        try await f.waitForRequestCount(4)
        #expect(f.requests[3].sha256 == f.hash("d"))
        try f.deliverChunk(for: "c", offset: 0)
        try await f.waitForRequestCount(5)
        #expect(f.requests[4].sha256 == f.hash("c"))
        #expect(f.requests[4].offset == UInt64(TourAssetTransferService.chunkSize))
        try f.deliverChunk(for: "d", offset: 0)
        try await f.waitForRequestCount(6)
        #expect(f.requests[5].sha256 == f.hash("a"))
        #expect(f.requests[5].offset == UInt64(TourAssetTransferService.chunkSize))
        try f.deliverChunk(for: "c", offset: UInt64(TourAssetTransferService.chunkSize))
        try await f.waitForRequestCount(7)
        #expect(f.requests[6].sha256 == f.hash("b"))
        #expect(f.requests[6].offset == UInt64(TourAssetTransferService.chunkSize))
        try f.deliverChunk(for: "a", offset: UInt64(TourAssetTransferService.chunkSize))
        try f.deliverChunk(for: "b", offset: UInt64(TourAssetTransferService.chunkSize))
        try await f.waitForReadyAssets(["a", "b", "c", "d"])
        #expect(try Data(contentsOf: f.readyURL("a")) == f.bytes("a"))
        #expect(try Data(contentsOf: f.readyURL("b")) == f.bytes("b"))
        #expect(f.requests.count == 7)
        #expect(f.failedStatuses.isEmpty)
    }

    @Test("Stopping during a cache resume cannot emit a stale request")
    @MainActor
    func stoppedGuestIgnoresSuspendedResume() async throws {
        let transport = LifecycleAssetTransport()
        let cache = SuspendedResumeCache()
        let service = TourAssetTransferService(transport: transport, cache: cache)
        defer { service.stop(); cache.cancel() }
        let session = UUID()
        service.configureSession(sessionID: session, participantID: UUID(), displayName: "Guest", platform: .iOS,
            credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: session))
        service.joinTour(hostIP: "127.0.0.1")
        let asset = try TourAssetDescriptor(assetID: "slide", kind: .slide, sha256: String(repeating: "a", count: 64),
            byteLength: 100, order: 0, mimeType: "image/jpeg")
        let manifest = try TourPackManifestPayload(packID: UUID(), manifestVersion: 1, displayName: "Tour", assets: [asset])
        transport.emit(.envelopeReceived(try SessionEnvelope(lane: .asset, kind: .tourPackManifest, sequence: 1,
            sessionID: session, senderID: UUID(), payload: manifest.encode())))
        try await waitUntil("suspended cache resume") { cache.isWaiting }
        service.stop()
        cache.resume()
        for _ in 0..<100 { await Task.yield() }
        #expect(transport.sent.filter { $0.kind == .assetRequest }.isEmpty)
    }

    @Test("Guide authentication failure stops guest content work terminally")
    @MainActor
    func authenticationFailureStopsGuestRequests() async throws {
        let f = try GuestFixture(sizes: ["a": 70_000, "b": 1_000])
        defer { f.close() }
        try f.deliverManifest()
        try await f.waitForRequestCount(2)
        f.transport.emit(.credentialRejected("Changed guide key"))
        try await f.waitUntil("asset transport stopped") { !f.transport.isActive }
        try f.deliverChunk(for: "a", offset: 0)
        for _ in 0..<100 { await Task.yield() }
        #expect(f.requests.count == 2)
        #expect(f.failedStatuses.isEmpty)
    }

    @Test("A queued authentication failure cannot stop a replacement asset session")
    @MainActor
    func queuedAssetFailureCannotCrossSessions() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000])
        defer { f.close() }
        f.transport.emit(.credentialRejected("old run"))
        let replacement = UUID()
        f.service.configureSession(sessionID: replacement, participantID: UUID(), displayName: "Guest", platform: .iOS,
            credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: replacement))
        f.service.joinTour(hostIP: "127.0.0.1")
        for _ in 0..<100 { await Task.yield() }
        #expect(f.transport.isActive)
        #expect(f.service.lastError == nil)
    }

    @Test("Interrupted transfer resumes past a corrupt cache entry and reports verified participant readiness")
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
        let styleSourceURL = root.appending(path: "style.json", directoryHint: .notDirectory)
        let spritesSourceURL = root.appending(path: "sprites.png", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data((0 ..< 150_000).map { UInt8($0 % 251) })
        let mapBytes = Data((0 ..< 80_000).map { UInt8(($0 * 7) % 251) })
        let styleBytes = Data((0 ..< 3_000).map { UInt8(($0 * 11) % 251) })
        let spritesBytes = Data((0 ..< 70_000).map { UInt8(($0 * 13) % 251) })
        try bytes.write(to: sourceURL, options: .atomic)
        try mapBytes.write(to: mapSourceURL, options: .atomic)
        try styleBytes.write(to: styleSourceURL, options: .atomic)
        try spritesBytes.write(to: spritesSourceURL, options: .atomic)
        let hash = Self.sha256(bytes)
        let mapHash = Self.sha256(mapBytes)
        let styleHash = Self.sha256(styleBytes)
        let spritesHash = Self.sha256(spritesBytes)
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
        let styleAsset = try TourAssetDescriptor(
            assetID: "alhambra-style",
            kind: .mapStyle,
            sha256: styleHash,
            byteLength: UInt64(styleBytes.count),
            order: 2,
            mimeType: "application/json"
        )
        let spritesAsset = try TourAssetDescriptor(
            assetID: "alhambra-sprites",
            kind: .mapSprites,
            sha256: spritesHash,
            byteLength: UInt64(spritesBytes.count),
            order: 3,
            mimeType: "image/png"
        )
        let packID = UUID()
        let manifest = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 1,
            displayName: "Alhambra",
            assets: [asset, mapAsset, styleAsset, spritesAsset]
        )

        let guideCache = try FileTourAssetCache(
            rootDirectory: root.appending(path: "guide-cache", directoryHint: .isDirectory)
        )
        let guestCacheRoot = root.appending(path: "guest-cache", directoryHint: .isDirectory)
        let guestCache = try FileTourAssetCache(rootDirectory: guestCacheRoot)
        let firstChunk = try AssetChunkPayload(
            sha256: hash,
            offset: 0,
            totalLength: UInt64(bytes.count),
            bytes: bytes.prefix(TourAssetTransferService.chunkSize)
        )
        #expect(try await guestCache.ingest(firstChunk) == .partial(
            nextOffset: UInt64(TourAssetTransferService.chunkSize)
        ))
        // A corrupt complete entry for the map (wrong length) must be repaired, not abort the pack.
        let corruptMapEntry = guestCacheRoot
            .appending(path: "complete", directoryHint: .isDirectory)
            .appending(path: mapHash, directoryHint: .notDirectory)
        try Data(repeating: 0, count: 10).write(to: corruptMapEntry, options: .atomic)

        let guideID = UUID()
        let guestID = UUID()
        let sessionID = UUID()
        let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        let guide = TourAssetTransferService(
            transport: LocalSessionAssetTransport(port: 50_012, authentication: .legacyFixture),
            cache: guideCache
        )
        let guest = TourAssetTransferService(
            transport: LocalSessionAssetTransport(port: 50_012, authentication: .legacyFixture),
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
                styleAsset.assetID: styleSourceURL,
                spritesAsset.assetID: spritesSourceURL,
            ]
        )

        let ready = try await readyURLs(
            for: ["gate-left", "alhambra-map", "alhambra-style", "alhambra-sprites"],
            from: guestEvents
        )
        let readyURL = try #require(ready["gate-left"])
        let readyMapURL = try #require(ready["alhambra-map"])
        #expect(try Data(contentsOf: readyURL) == bytes)
        #expect(try Data(contentsOf: readyMapURL) == mapBytes)
        #expect(try Data(contentsOf: try #require(ready["alhambra-style"])) == styleBytes)
        #expect(try Data(contentsOf: try #require(ready["alhambra-sprites"])) == spritesBytes)

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

    // MARK: - Bounded, self-repairing guest pipeline over a recording transport

    @Test("Manifest requests are capped at two in flight and refilled as assets finish")
    @MainActor
    func manifestRequestsAreCappedAtTwoInFlight() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000, "b": 70_000, "c": 1_000, "d": 1_000])
        defer { f.close() }
        // A wrong-length complete entry for B must be repaired without aborting the pack.
        try f.writeCorruptCompleteEntry(for: "b", byteCount: 10)

        try f.deliverManifest()
        try await f.waitForRequestCount(2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.requests.map(\.sha256) == [f.hash("a"), f.hash("b")], "only two assets may be in flight")
        #expect(f.requests.map(\.offset) == [0, 0])

        try f.deliverChunk(for: "a", offset: 0)
        try await f.waitForRequestCount(3)
        #expect(f.readyStatuses.map(\.sha256) == [f.hash("a")])
        #expect(f.requests[2].sha256 == f.hash("c"))

        try f.deliverChunk(for: "b", offset: 0)
        try await f.waitForRequestCount(4)
        #expect(f.requests[3].sha256 == f.hash("b"))
        #expect(f.requests[3].offset == UInt64(TourAssetTransferService.chunkSize))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.requests.count == 4, "D must wait for a free slot")

        try f.deliverChunk(for: "c", offset: 0)
        try await f.waitForRequestCount(5)
        #expect(f.requests[4].sha256 == f.hash("d"))

        try f.deliverChunk(for: "b", offset: UInt64(TourAssetTransferService.chunkSize))
        try f.deliverChunk(for: "d", offset: 0)
        try await f.waitForReadyAssets(["a", "b", "c", "d"])
        #expect(try Data(contentsOf: f.readyURL("b")) == f.bytes("b"))
        #expect(f.requests.count == 5)
        #expect(f.failedStatuses.isEmpty)
        #expect(f.service.lastError == nil)
    }

    @Test("A checksum mismatch is re-requested once from offset zero and recovers")
    @MainActor
    func checksumMismatchIsReRequestedOnceAndRecovers() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000])
        defer { f.close() }

        try f.deliverManifest()
        try await f.waitForRequestCount(1)
        try f.deliverCorruptChunk(for: "a")
        try await f.waitForRequestCount(2)
        #expect(f.requests[1].sha256 == f.hash("a"))
        #expect(f.requests[1].offset == 0)
        #expect(f.failedStatuses.isEmpty)
        #expect(f.failedEvents.isEmpty)

        try f.deliverChunk(for: "a", offset: 0)
        try await f.waitForReadyAssets(["a"])
        #expect(f.readyStatuses.map(\.sha256) == [f.hash("a")])
        #expect(f.failedEvents.isEmpty)
        #expect(f.service.lastError == nil)
    }

    @Test("A second checksum mismatch sends FAILED and releases the slot")
    @MainActor
    func secondChecksumMismatchSendsFailedStatusAndReleasesSlot() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000, "b": 1_000, "c": 1_000])
        defer { f.close() }

        try f.deliverManifest()
        try await f.waitForRequestCount(2)
        try f.deliverCorruptChunk(for: "a")
        try await f.waitForRequestCount(3)
        #expect(f.requests[2].sha256 == f.hash("a"), "first mismatch re-requests A")

        try f.deliverChunk(for: "b", offset: 0)
        try await f.waitForRequestCount(4)
        #expect(f.requests[3].sha256 == f.hash("c"), "B's slot goes to C")

        try f.deliverCorruptChunk(for: "a")
        try await f.waitUntil("FAILED status for A") { !f.failedStatuses.isEmpty }
        #expect(f.failedStatuses.map(\.sha256) == [f.hash("a")])
        #expect(f.failedStatuses.first?.detail.contains("checksum mismatch") == true)
        #expect(!f.failedEvents.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.requests.filter { $0.sha256 == f.hash("a") }.count == 2, "no third request for A")

        try f.deliverChunk(for: "c", offset: 0)
        try await f.waitForReadyAssets(["b", "c"])
        #expect(f.requests.count == 4)
    }

    @Test("Disconnect resets the in-flight queue so a rejoin manifest re-requests everything")
    @MainActor
    func disconnectResetsInFlightRequests() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000, "b": 1_000])
        defer { f.close() }

        try f.deliverManifest()
        try await f.waitForRequestCount(2)

        f.transport.emit(.disconnected)
        try f.deliverManifest()
        try await f.waitForRequestCount(4)
        #expect(f.requests.map(\.sha256) == [f.hash("a"), f.hash("b"), f.hash("a"), f.hash("b")])
        #expect(f.requests.map(\.offset) == [0, 0, 0, 0])

        try f.deliverChunk(for: "a", offset: 0)
        try f.deliverChunk(for: "b", offset: 0)
        try await f.waitForReadyAssets(["a", "b"])
        #expect(f.failedStatuses.isEmpty)
        #expect(f.service.lastError == nil)
    }

    @Test("An unanswered request releases its slot after the inactivity deadline")
    @MainActor
    func unansweredRequestReleasesSlotAfterDeadline() async throws {
        let f = try GuestFixture(sizes: ["a": 1_000, "b": 1_000, "c": 1_000, "d": 1_000], inFlightDeadline: .milliseconds(300))
        defer { f.close() }

        try f.deliverManifest()
        try await f.waitForRequestCount(2)
        #expect(f.requests.map(\.sha256) == [f.hash("a"), f.hash("b")])

        // Serve nothing: both deadlines expire, report FAILED, and free the slots for C and D.
        try await f.waitForRequestCount(4)
        #expect(f.requests[2].sha256 == f.hash("c"))
        #expect(f.requests[3].sha256 == f.hash("d"))
        // Both deadlines expire in the same instant; sibling task resumption order is not defined.
        #expect(Set(f.failedStatuses.map(\.sha256)) == [f.hash("a"), f.hash("b")])
        #expect(f.failedStatuses.map(\.detail) == ["no chunk received within 0.3 s", "no chunk received within 0.3 s"])
        #expect(Set(f.failedEvents) == ["Asset a: no chunk received within 0.3 s", "Asset b: no chunk received within 0.3 s"])

        try f.deliverChunk(for: "c", offset: 0)
        try f.deliverChunk(for: "d", offset: 0)
        try await f.waitForReadyAssets(["c", "d"])
        #expect(f.readyStatuses.map(\.sha256) == [f.hash("c"), f.hash("d")])
        #expect(f.requests.count == 4)
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !condition() {
            guard clock.now < deadline else { throw TestTimeout.expired(description) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private final class GuideFixture {
        struct Chunk { let memberID: UUID?; let payload: AssetChunkPayload }
        let transport = LifecycleAssetTransport()
        let reader: SuspendedChunkReader
        let service: TourAssetTransferService
        private let root: URL
        private let sessionID = UUID()
        private var sequence: UInt64 = 0
        private var manifest: TourPackManifestPayload
        private var sources: [String: URL] = [:]
        private var contents: [String: Data] = [:]

        init() async throws {
            let reader = SuspendedChunkReader()
            self.reader = reader
            root = FileManager.default.temporaryDirectory.appending(path: "GetOverHereGuideSchedule-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var descriptors: [TourAssetDescriptor] = []
            for (index, id) in ["a", "b"].enumerated() {
                let data = Data((0..<70_000).map { UInt8(($0 * (index + 3)) % 251) })
                let url = root.appending(path: "\(id).bin")
                try data.write(to: url)
                sources[id] = url; contents[id] = data
                descriptors.append(try TourAssetDescriptor(assetID: id, kind: .slide,
                    sha256: TourAssetTransferServiceTests.sha256(data), byteLength: UInt64(data.count),
                    order: UInt32(index), mimeType: "image/jpeg"))
            }
            manifest = try TourPackManifestPayload(packID: UUID(), manifestVersion: 1, displayName: "Tour", assets: descriptors)
            service = TourAssetTransferService(transport: transport,
                cache: try FileTourAssetCache(rootDirectory: root.appending(path: "cache", directoryHint: .isDirectory)),
                readSourceChunk: { url, hash, offset, count in try await reader.read(url: url, hash: hash, offset: offset, count: count) })
            service.configureSession(sessionID: sessionID, participantID: UUID(), displayName: "Guide", platform: .iOS,
                credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID))
            try await service.hostTourPack(manifest, sourcesByAssetID: sources)
        }

        func close() {
            service.stop(); reader.cancelAll()
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Guide fixture cleanup failed: \(error)") }
        }
        func bytes(_ id: String) -> Data { contents[id]! }
        func hash(_ id: String) -> String { manifest.assets.first { $0.assetID == id }!.sha256 }
        func join(_ member: UUID) {
            transport.emit(.guestJoined(ParticipantSession(participantID: member, connectionID: UUID().uuidString,
                displayName: "Guest", role: .guest, platform: .iOS)))
        }
        func request(_ member: UUID, assetID: String, offset: UInt64 = 0) throws {
            try deliver(member: member, kind: .assetRequest, payload: AssetRequestPayload(sha256: hash(assetID), offset: offset).encode())
        }
        func deliver(member: UUID, kind: SessionMessageKind, payload: Data) throws {
            sequence += 1
            transport.emit(.envelopeReceived(try SessionEnvelope(lane: .asset, kind: kind, sequence: sequence,
                sessionID: sessionID, senderID: member, payload: payload)))
        }
        func replaceManifest() async throws {
            manifest = try TourPackManifestPayload(packID: manifest.packID, manifestVersion: manifest.manifestVersion + 1,
                displayName: manifest.displayName, assets: manifest.assets)
            try await service.hostTourPack(manifest, sourcesByAssetID: sources)
        }
        var chunks: [Chunk] {
            transport.sent.filter { $0.kind == .assetChunk }.compactMap {
                do { return Chunk(memberID: $0.to, payload: try AssetChunkPayload.decode($0.payload)) }
                catch { Issue.record("Invalid recorded chunk: \(error)"); return nil }
            }
        }
    }

    nonisolated private final class SuspendedChunkReader: @unchecked Sendable {
        private struct Read {
            let url: URL; let offset: UInt64; let count: Int
            let continuation: CheckedContinuation<Data, any Error>
        }
        private let lock = NSLock()
        private var pending: [Read] = []
        private var total = 0
        private var peak = 0
        var readCount: Int { lock.withLock { total } }
        var maximumPending: Int { lock.withLock { peak } }
        func read(url: URL, hash: String, offset: UInt64, count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending.append(Read(url: url, offset: offset, count: count, continuation: continuation))
                    total += 1; peak = max(peak, pending.count)
                }
            }
        }
        func releaseNext() throws {
            let read = try lock.withLock { try #require(pending.isEmpty ? nil : pending.removeFirst()) }
            do {
                let data = try Data(contentsOf: read.url)
                read.continuation.resume(returning: Data(data[Int(read.offset)..<(Int(read.offset) + read.count)]))
            } catch { read.continuation.resume(throwing: error); throw error }
        }
        func cancelAll() {
            let reads = lock.withLock { let reads = pending; pending.removeAll(); return reads }
            reads.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
    }

    nonisolated private final class SuspendedResumeCache: TourAssetCache, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<UInt64, any Error>?
        var isWaiting: Bool { lock.withLock { pending != nil } }
        func readyURL(sha256: String, expectedLength: UInt64) async throws -> URL? { nil }
        func resumeOffset(sha256: String, expectedLength: UInt64) async throws -> UInt64 {
            try await withCheckedThrowingContinuation { continuation in lock.withLock { pending = continuation } }
        }
        func ingest(_ chunk: AssetChunkPayload) async throws -> AssetCacheIngestResult { throw CancellationError() }
        func discardPartial(sha256: String) async throws {}
        func resume() { take()?.resume(returning: 0) }
        func cancel() { take()?.resume(throwing: CancellationError()) }
        private func take() -> CheckedContinuation<UInt64, any Error>? {
            lock.withLock { let current = pending; pending = nil; return current }
        }
    }

    /// A guest `TourAssetTransferService` over G4's recording `LifecycleAssetTransport`: the test plays
    /// the guide by delivering manifest and chunk envelopes and reads back requests and statuses.
    @MainActor
    private final class GuestFixture {
        let transport = LifecycleAssetTransport()
        let service: TourAssetTransferService
        let manifest: TourPackManifestPayload
        private let root: URL
        private let cacheRoot: URL
        private let guideID = UUID()
        private let sessionID = UUID()
        private var descriptors: [String: TourAssetDescriptor] = [:]
        private var contents: [String: Data] = [:]
        private var sequence: UInt64 = 0
        private let events = EventRecorder()

        init(sizes: [String: Int], inFlightDeadline: Duration? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "GetOverHereGuestFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
            cacheRoot = root.appending(path: "cache", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var assets: [TourAssetDescriptor] = []
            for (index, assetID) in sizes.keys.sorted().enumerated() {
                let count = sizes[assetID]!
                let seed = UInt8(truncatingIfNeeded: index + 3)
                let data = Data((0 ..< count).map { UInt8(truncatingIfNeeded: ($0 &* Int(seed)) % 251) })
                contents[assetID] = data
                let descriptor = try TourAssetDescriptor(
                    assetID: assetID,
                    kind: .slide,
                    sha256: TourAssetTransferServiceTests.sha256(data),
                    byteLength: UInt64(count),
                    order: UInt32(index),
                    mimeType: "image/jpeg"
                )
                descriptors[assetID] = descriptor
                assets.append(descriptor)
            }
            manifest = try TourPackManifestPayload(
                packID: UUID(),
                manifestVersion: 1,
                displayName: "Pack",
                assets: assets
            )
            let cache = try FileTourAssetCache(rootDirectory: cacheRoot)
            if let inFlightDeadline {
                service = TourAssetTransferService(transport: transport, cache: cache, inFlightDeadline: inFlightDeadline)
            } else {
                service = TourAssetTransferService(transport: transport, cache: cache)
            }
            let events = self.events
            service.setEventHandler { events.append($0) }
            service.configureSession(
                sessionID: sessionID,
                participantID: UUID(),
                displayName: "Guest",
                platform: .iOS,
                credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
            )
            service.joinTour(hostIP: "127.0.0.1")
        }

        func close() {
            service.stop()
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Guest fixture cleanup failed (\(String(describing: type(of: error))))\n", stderr) }
        }

        func hash(_ assetID: String) -> String { descriptors[assetID]!.sha256 }
        func bytes(_ assetID: String) -> Data { contents[assetID]! }

        var requests: [AssetRequestPayload] {
            transport.sent.filter { $0.kind == .assetRequest }.compactMap { sent in
                do { return try AssetRequestPayload.decode(sent.payload) }
                catch { Issue.record("Undecodable request: \(error)"); return nil }
            }
        }

        private var statuses: [AssetStatusPayload] {
            transport.sent.filter { $0.kind == .assetStatus }.compactMap { sent in
                do { return try AssetStatusPayload.decode(sent.payload) }
                catch { Issue.record("Undecodable status: \(error)"); return nil }
            }
        }

        var readyStatuses: [AssetStatusPayload] { statuses.filter { $0.status == .ready } }
        var failedStatuses: [AssetStatusPayload] { statuses.filter { $0.status == .failed } }

        var failedEvents: [String] {
            events.snapshot().compactMap { if case let .failed(message) = $0 { message } else { nil } }
        }

        var readyAssetIDs: [String] {
            events.snapshot().compactMap { if case let .assetReady(assetID, _) = $0 { assetID } else { nil } }
        }

        func readyURL(_ assetID: String) throws -> URL {
            try #require(service.readyURLsByAssetID[assetID])
        }

        func writeCorruptCompleteEntry(for assetID: String, byteCount: Int) throws {
            let url = cacheRoot
                .appending(path: "complete", directoryHint: .isDirectory)
                .appending(path: hash(assetID), directoryHint: .notDirectory)
            try Data(repeating: 0, count: byteCount).write(to: url, options: .atomic)
        }

        func deliverManifest() throws {
            try deliver(kind: .tourPackManifest, payload: try manifest.encode())
        }

        func deliverChunk(for assetID: String, offset: UInt64) throws {
            let data = bytes(assetID)
            let end = min(data.count, Int(offset) + TourAssetTransferService.chunkSize)
            let chunk = try AssetChunkPayload(
                sha256: hash(assetID),
                offset: offset,
                totalLength: UInt64(data.count),
                bytes: Data(data[Int(offset) ..< end])
            )
            try deliver(kind: .assetChunk, payload: try chunk.encode())
        }

        /// A full-length chunk of 0xFF bytes under the asset's real hash: the cache rejects it on verify.
        func deliverCorruptChunk(for assetID: String) throws {
            let count = bytes(assetID).count
            precondition(count <= TourAssetTransferService.chunkSize, "corrupt chunk must be a single chunk")
            let chunk = try AssetChunkPayload(
                sha256: hash(assetID),
                offset: 0,
                totalLength: UInt64(count),
                bytes: Data(repeating: 0xff, count: count)
            )
            try deliver(kind: .assetChunk, payload: try chunk.encode())
        }

        private func deliver(kind: SessionMessageKind, payload: Data) throws {
            sequence += 1
            transport.emit(.envelopeReceived(try SessionEnvelope(
                lane: .asset,
                kind: kind,
                sequence: sequence,
                sessionID: sessionID,
                senderID: guideID,
                payload: payload
            )))
        }

        func waitForRequestCount(_ count: Int) async throws {
            try await waitUntil("\(count) asset requests") { requests.count >= count }
            #expect(requests.count == count, "request burst exceeded the expected count")
        }

        func waitForReadyAssets(_ assetIDs: [String]) async throws {
            try await waitUntil("assets ready: \(assetIDs)") { Set(assetIDs).isSubset(of: Set(readyAssetIDs)) }
        }

        func waitUntil(
            _ description: String,
            timeout: Duration = .seconds(5),
            _ condition: () -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while !condition() {
                if clock.now > deadline { throw TestTimeout.expired(description) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [TourAssetTransferEvent] = []

        func append(_ event: TourAssetTransferEvent) {
            lock.withLock { events.append(event) }
        }

        func snapshot() -> [TourAssetTransferEvent] {
            lock.withLock { events }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Drains the stream until every listed asset is ready, in whatever order the transfers finish.
    private func readyURLs(
        for assetIDs: Set<String>,
        from stream: AsyncStream<TourAssetTransferEvent>
    ) async throws -> [String: URL] {
        try await withThrowingTaskGroup(of: [String: URL].self) { group in
            group.addTask {
                var ready: [String: URL] = [:]
                for await event in stream {
                    if case let .assetReady(assetID, url) = event, assetIDs.contains(assetID) {
                        ready[assetID] = url
                        if ready.count == assetIDs.count { return ready }
                    }
                }
                throw TestTimeout.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TestTimeout.expired("assets ready: \(assetIDs.sorted())")
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
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
                throw TestTimeout.expired("asset event")
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }
}
