import CryptoKit
import Foundation
import Observation
import TourSessionCore

enum TourAssetTransferEvent: Sendable {
    case manifestReceived(TourPackManifestPayload)
    case assetReady(assetID: String, url: URL)
    case participantReady(UUID)
    case failed(String)
}

enum TourAssetTransferError: LocalizedError {
    case sourceMissing(String)
    case sourceLengthMismatch(assetID: String, expected: UInt64, actual: UInt64)
    case sourceChecksumMismatch(assetID: String, expected: String, actual: String)
    case unknownAssetHash(String)
    case invalidRequestOffset(hash: String, offset: UInt64, length: UInt64)
    case chunkLengthMismatch(hash: String, expected: UInt64, actual: UInt64)
    case shortRead(hash: String, expected: Int, actual: Int)
    case sourceSizeUnavailable(String)
    case unexpectedMessage(SessionMessageKind)

    var errorDescription: String? {
        switch self {
        case let .sourceMissing(assetID): "Source is missing for asset \(assetID)"
        case let .sourceLengthMismatch(assetID, expected, actual):
            "Source length mismatch for \(assetID): expected \(expected), got \(actual)"
        case let .sourceChecksumMismatch(assetID, expected, actual):
            "Source checksum mismatch for \(assetID): expected \(expected), got \(actual)"
        case let .unknownAssetHash(hash): "Unknown requested asset hash \(hash)"
        case let .invalidRequestOffset(hash, offset, length):
            "Invalid request offset \(offset) for \(hash) with length \(length)"
        case let .chunkLengthMismatch(hash, expected, actual):
            "Chunk length mismatch for \(hash): expected \(expected), got \(actual)"
        case let .shortRead(hash, expected, actual):
            "Short source read for \(hash): expected \(expected), got \(actual)"
        case let .sourceSizeUnavailable(assetID): "Could not read source size for \(assetID)"
        case let .unexpectedMessage(kind): "Unexpected asset-channel message \(kind)"
        }
    }
}

@Observable
@MainActor
final class TourAssetTransferService {
    private enum Role {
        case guide
        case guest
    }

    private struct GuideSource: Sendable {
        let descriptor: TourAssetDescriptor
        let url: URL
    }

    static let chunkSize = 65_536
    /// The asset lane's per-peer writer holds 8 frames and disconnects on overflow
    /// (`LocalSessionControlTransport`, ADR-039); two in-flight assets keep at most two 64 KiB chunks
    /// queued per guest.
    nonisolated static let maxInFlightRequests = 2
    /// A checksum-mismatched asset is re-requested once from offset 0, then reported FAILED.
    nonisolated static let maxTransferAttempts = 2
    /// An in-flight request with no chunk for this long is reported FAILED and releases its slot
    /// (DSCN-16); the guide has no failure frame for an unanswerable request. Nonisolated so the
    /// `init` default argument can read it.
    nonisolated static let inFlightDeadline: Duration = .seconds(15)

    private(set) var manifest: TourPackManifestPayload?
    private(set) var readyURLsByAssetID: [String: URL] = [:]
    private(set) var connectedParticipantIDs: Set<UUID> = []
    private(set) var readyParticipantIDs: Set<UUID> = []
    private(set) var lastError: String?

    @ObservationIgnored private let transport: SessionAssetTransport
    @ObservationIgnored private let cache: TourAssetCache
    @ObservationIgnored private var role: Role?
    @ObservationIgnored private var sourcesByHash: [String: GuideSource] = [:]
    @ObservationIgnored private var readyHashesByParticipant: [UUID: Set<String>] = [:]
    @ObservationIgnored private var eventHandler: (@Sendable (TourAssetTransferEvent) -> Void)?
    @ObservationIgnored private let requestDeadline: Duration
    /// Guest request scheduler (FND-9): ordered unique hashes waiting for a slot, hashes with an
    /// outstanding request, failed full-transfer counts, and the per-hash inactivity deadline.
    @ObservationIgnored private var pendingHashes: [String] = []
    @ObservationIgnored private var inFlightHashes: Set<String> = []
    @ObservationIgnored private var transferAttempts: [String: Int] = [:]
    @ObservationIgnored private var inFlightDeadlines: [String: Task<Void, Never>] = [:]

    init(
        transport: SessionAssetTransport,
        cache: TourAssetCache,
        inFlightDeadline: Duration = TourAssetTransferService.inFlightDeadline
    ) {
        self.transport = transport
        self.cache = cache
        requestDeadline = inFlightDeadline
        transport.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handle(event)
            }
        }
    }

    func setEventHandler(_ handler: (@Sendable (TourAssetTransferEvent) -> Void)?) {
        eventHandler = handler
    }

    func configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential
    ) {
        transport.configureSession(
            sessionID: sessionID,
            participantID: participantID,
            displayName: displayName,
            platform: platform,
            credential: credential
        )
    }

    func hostTourPack(
        _ manifest: TourPackManifestPayload,
        sourcesByAssetID: [String: URL]
    ) async throws {
        let validated = try await Self.validateSources(
            manifest: manifest,
            sourcesByAssetID: sourcesByAssetID
        )
        let isUpdatingActiveGuide = role == .guide && transport.isActive
        role = .guide
        self.manifest = manifest
        sourcesByHash = validated
        readyHashesByParticipant.removeAll()
        readyParticipantIDs.removeAll()
        if manifest.assets.isEmpty {
            readyParticipantIDs = connectedParticipantIDs
        }
        if isUpdatingActiveGuide {
            transport.send(kind: .tourPackManifest, payload: try manifest.encode(), to: nil)
        } else {
            connectedParticipantIDs.removeAll()
            try transport.startGuide()
        }
    }

    func startGuideWithEmptyTourPack(_ manifest: TourPackManifestPayload) throws {
        guard manifest.assets.isEmpty else {
            throw TourAssetTransferError.sourceMissing("startGuideWithEmptyTourPack requires an empty manifest")
        }
        role = .guide
        self.manifest = manifest
        sourcesByHash.removeAll()
        readyHashesByParticipant.removeAll()
        readyParticipantIDs.removeAll()
        connectedParticipantIDs.removeAll()
        try transport.startGuide()
    }

    func joinTour(hostIP: String) {
        role = .guest
        transport.hostIP = hostIP
        transport.startGuest()
    }

    func stop() {
        transport.stop()
        role = nil
        connectedParticipantIDs.removeAll()
        resetGuestTransferQueue()
    }

    func clearSession() {
        stop()
        transport.clearSession()
    }

    func isParticipantReady(_ participantID: UUID) -> Bool {
        readyParticipantIDs.contains(participantID)
    }

    private func handle(_ event: SessionAssetEvent) async {
        switch event {
        case let .guestJoined(participant):
            guard role == .guide, let manifest else { return }
            connectedParticipantIDs.insert(participant.participantID)
            do {
                transport.send(
                    kind: .tourPackManifest,
                    payload: try manifest.encode(),
                    to: participant.participantID
                )
                if manifest.assets.isEmpty {
                    readyParticipantIDs.insert(participant.participantID)
                }
            } catch {
                report(error)
            }
        case let .envelopeReceived(envelope):
            await handle(envelope)
        case let .guestDisconnected(participantID):
            connectedParticipantIDs.remove(participantID)
            readyHashesByParticipant.removeValue(forKey: participantID)
            readyParticipantIDs.remove(participantID)
        case .connected:
            break
        case .disconnected:
            // The guide re-sends the manifest on rejoin; the guest must re-request from a clean queue.
            resetGuestTransferQueue()
        case let .versionMismatch(remoteMajor, localMajor):
            report("Tour protocol version mismatch (remote \(remoteMajor), local \(localMajor)). Update the older app.")
        case let .credentialRejected(message):
            report(message)
        case let .failed(message):
            report(message)
        }
    }

    private func handle(_ envelope: SessionEnvelope) async {
        do {
            switch (role, envelope.kind) {
            case (.guide, .assetRequest):
                try await handleGuideRequest(
                    try AssetRequestPayload.decode(envelope.payload),
                    participantID: envelope.senderID
                )
            case (.guide, .assetStatus):
                try handleGuideStatus(
                    try AssetStatusPayload.decode(envelope.payload),
                    participantID: envelope.senderID
                )
            case (.guest, .tourPackManifest):
                try await handleGuestManifest(try TourPackManifestPayload.decode(envelope.payload))
            case (.guest, .assetChunk):
                try await handleGuestChunk(try AssetChunkPayload.decode(envelope.payload))
            default:
                throw TourAssetTransferError.unexpectedMessage(envelope.kind)
            }
        } catch {
            report(error)
            if role == .guest, let hash = hashIfAvailable(in: envelope) {
                sendStatus(hash: hash, status: .failed, byteLength: 0, detail: error.localizedDescription)
                await finishTransfer(hash)
            }
        }
    }

    private func handleGuideRequest(
        _ request: AssetRequestPayload,
        participantID: UUID
    ) async throws {
        guard let source = sourcesByHash[request.sha256] else {
            throw TourAssetTransferError.unknownAssetHash(request.sha256)
        }
        let length = source.descriptor.byteLength
        guard request.offset < length else {
            throw TourAssetTransferError.invalidRequestOffset(
                hash: request.sha256,
                offset: request.offset,
                length: length
            )
        }
        let remaining = length - request.offset
        let count = min(Self.chunkSize, Int(remaining))
        let bytes = try await Self.readChunk(
            source.url,
            hash: request.sha256,
            offset: request.offset,
            count: count
        )
        let chunk = try AssetChunkPayload(
            sha256: request.sha256,
            offset: request.offset,
            totalLength: length,
            bytes: bytes
        )
        transport.send(kind: .assetChunk, payload: try chunk.encode(), to: participantID)
    }

    private func handleGuideStatus(_ status: AssetStatusPayload, participantID: UUID) throws {
        guard let manifest,
              let descriptor = manifest.assets.first(where: { $0.sha256 == status.sha256 }) else {
            throw TourAssetTransferError.unknownAssetHash(status.sha256)
        }
        guard status.status == .ready else {
            report("Guest asset failure for \(status.sha256): \(status.detail)")
            return
        }
        guard status.byteLength == descriptor.byteLength else {
            throw TourAssetTransferError.chunkLengthMismatch(
                hash: status.sha256,
                expected: descriptor.byteLength,
                actual: status.byteLength
            )
        }
        readyHashesByParticipant[participantID, default: []].insert(status.sha256)
        let expected = Set(manifest.assets.map(\.sha256))
        if expected.isSubset(of: readyHashesByParticipant[participantID, default: []]) {
            readyParticipantIDs.insert(participantID)
            eventHandler?(.participantReady(participantID))
        }
    }

    private func handleGuestManifest(_ manifest: TourPackManifestPayload) async throws {
        if let current = self.manifest,
           current.packID == manifest.packID,
           current.manifestVersion > manifest.manifestVersion {
            return
        }
        self.manifest = manifest
        eventHandler?(.manifestReceived(manifest))

        // Hashes still in flight from the previous manifest keep their slot and are not re-requested,
        // which avoids a duplicate-chunk offsetMismatch; everything else is rebuilt from this manifest.
        let wanted = Set(manifest.assets.map(\.sha256))
        pendingHashes.removeAll()
        for hash in inFlightHashes where !wanted.contains(hash) {
            inFlightDeadlines.removeValue(forKey: hash)?.cancel()
        }
        inFlightHashes.formIntersection(wanted)
        transferAttempts = transferAttempts.filter { wanted.contains($0.key) }

        var seen = Set<String>()
        for descriptor in manifest.assets {
            guard seen.insert(descriptor.sha256).inserted, !inFlightHashes.contains(descriptor.sha256) else {
                continue
            }
            // Every asset is isolated: one cache failure reports FAILED for that asset and the loop goes on.
            do {
                if let ready = try await cache.readyURL(
                    sha256: descriptor.sha256,
                    expectedLength: descriptor.byteLength
                ) {
                    markReady(hash: descriptor.sha256, url: ready)
                    sendStatus(
                        hash: descriptor.sha256,
                        status: .ready,
                        byteLength: descriptor.byteLength,
                        detail: ""
                    )
                } else {
                    pendingHashes.append(descriptor.sha256)
                }
            } catch {
                report(error)
                sendStatus(hash: descriptor.sha256, status: .failed, byteLength: 0, detail: error.localizedDescription)
            }
        }
        await pumpRequests()
    }

    /// Starts requests until `maxInFlightRequests` are outstanding. The slot is reserved before the
    /// cache await so a reentrant pump can never exceed the cap.
    private func pumpRequests() async {
        while inFlightHashes.count < Self.maxInFlightRequests, !pendingHashes.isEmpty {
            let hash = pendingHashes.removeFirst()
            guard let descriptor = manifest?.assets.first(where: { $0.sha256 == hash }) else {
                fputs("Asset transfer: dropping pending hash \(hash) that is no longer in the manifest\n", stderr)
                continue
            }
            inFlightHashes.insert(hash)
            do {
                let offset = try await cache.resumeOffset(sha256: hash, expectedLength: descriptor.byteLength)
                try sendRequest(hash: hash, offset: offset)
            } catch {
                inFlightHashes.remove(hash)
                inFlightDeadlines.removeValue(forKey: hash)?.cancel()
                report(error)
                sendStatus(hash: hash, status: .failed, byteLength: 0, detail: error.localizedDescription)
            }
        }
    }

    private func finishTransfer(_ hash: String) async {
        inFlightHashes.remove(hash)
        transferAttempts.removeValue(forKey: hash)
        inFlightDeadlines.removeValue(forKey: hash)?.cancel()
        await pumpRequests()
    }

    private func resetGuestTransferQueue() {
        pendingHashes.removeAll()
        inFlightHashes.removeAll()
        transferAttempts.removeAll()
        for task in inFlightDeadlines.values { task.cancel() }
        inFlightDeadlines.removeAll()
    }

    /// Re-armed on every request for `hash`; cancelled when the transfer finishes or the queue resets.
    private func armInFlightDeadline(hash: String) {
        inFlightDeadlines[hash]?.cancel()
        let deadline = requestDeadline
        inFlightDeadlines[hash] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch is CancellationError {
                return // the transfer finished, was re-armed, or the queue was reset
            } catch {
                fputs("Asset transfer: deadline sleep failed (\(String(describing: type(of: error))))\n", stderr)
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireInFlightRequest(hash: hash)
        }
    }

    private func expireInFlightRequest(hash: String) async {
        guard inFlightHashes.contains(hash) else { return }
        inFlightDeadlines.removeValue(forKey: hash)
        let detail = "no chunk received within \(Self.describe(requestDeadline))"
        let assetID = manifest?.assets.first(where: { $0.sha256 == hash })?.assetID ?? hash
        report("Asset \(assetID): \(detail)")
        sendStatus(hash: hash, status: .failed, byteLength: 0, detail: detail)
        await finishTransfer(hash)
    }

    private static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%g s", seconds)
    }

    private func handleGuestChunk(_ chunk: AssetChunkPayload) async throws {
        guard let manifest,
              let descriptor = manifest.assets.first(where: { $0.sha256 == chunk.sha256 }) else {
            throw TourAssetTransferError.unknownAssetHash(chunk.sha256)
        }
        guard chunk.totalLength == descriptor.byteLength else {
            throw TourAssetTransferError.chunkLengthMismatch(
                hash: chunk.sha256,
                expected: descriptor.byteLength,
                actual: chunk.totalLength
            )
        }
        // Every chunk follows a request and every request reserves a slot, so the only chunk that
        // arrives without one is a late answer after the inactivity deadline already reported FAILED.
        guard inFlightHashes.contains(chunk.sha256) else {
            fputs("Asset transfer: ignoring chunk for \(chunk.sha256) that is no longer in flight\n", stderr)
            return
        }

        let result: AssetCacheIngestResult
        do {
            result = try await cache.ingest(chunk)
        } catch AssetCacheError.checksumMismatch(let expected, let actual) {
            // The cache already deleted the partial, so a retry restarts at offset 0.
            let failed = (transferAttempts[chunk.sha256] ?? 0) + 1
            transferAttempts[chunk.sha256] = failed
            guard failed < Self.maxTransferAttempts else {
                throw AssetCacheError.checksumMismatch(expected: expected, actual: actual)
            }
            fputs("Asset transfer: checksum mismatch for \(chunk.sha256) (attempt \(failed) of \(Self.maxTransferAttempts)); re-requesting from offset 0\n", stderr)
            try sendRequest(hash: chunk.sha256, offset: 0)
            return
        }

        switch result {
        case let .partial(nextOffset):
            try sendRequest(hash: chunk.sha256, offset: nextOffset)
        case let .ready(url):
            markReady(hash: chunk.sha256, url: url)
            sendStatus(
                hash: chunk.sha256,
                status: .ready,
                byteLength: chunk.totalLength,
                detail: ""
            )
            await finishTransfer(chunk.sha256)
        }
    }

    private func sendRequest(hash: String, offset: UInt64) throws {
        let request = try AssetRequestPayload(sha256: hash, offset: offset)
        transport.send(kind: .assetRequest, payload: try request.encode(), to: nil)
        armInFlightDeadline(hash: hash)
    }

    private func sendStatus(
        hash: String,
        status: AssetTransferStatus,
        byteLength: UInt64,
        detail: String
    ) {
        do {
            let payload = try AssetStatusPayload(
                sha256: hash,
                status: status,
                byteLength: byteLength,
                detail: String(detail.prefix(1024))
            )
            transport.send(kind: .assetStatus, payload: try payload.encode(), to: nil)
        } catch {
            report(error)
        }
    }

    private func markReady(hash: String, url: URL) {
        guard let manifest else { return }
        for descriptor in manifest.assets where descriptor.sha256 == hash {
            let wasMissing = readyURLsByAssetID[descriptor.assetID] == nil
            readyURLsByAssetID[descriptor.assetID] = url
            if wasMissing {
                eventHandler?(.assetReady(assetID: descriptor.assetID, url: url))
            }
        }
    }

    private func hashIfAvailable(in envelope: SessionEnvelope) -> String? {
        switch envelope.kind {
        case .assetChunk:
            do {
                return try AssetChunkPayload.decode(envelope.payload).sha256
            } catch {
                fputs("Asset transfer: could not recover failed chunk hash (\(String(describing: type(of: error))))\n", stderr)
                return nil
            }
        case .tourPackManifest, .assetRequest, .assetStatus, .assetManifest,
             .hello, .authChallenge, .welcome, .heartbeat, .leave, .audioFrame,
             .presentationSnapshot, .bearingSnapshot, .targetSnapshot, .visualFocusSnapshot:
            return nil
        }
    }

    private func report(_ error: Error) {
        report(error.localizedDescription)
    }

    private func report(_ message: String) {
        lastError = message
        eventHandler?(.failed(message))
    }

    @concurrent
    private static func validateSources(
        manifest: TourPackManifestPayload,
        sourcesByAssetID: [String: URL]
    ) async throws -> [String: GuideSource] {
        var result: [String: GuideSource] = [:]
        for descriptor in manifest.assets {
            guard let url = sourcesByAssetID[descriptor.assetID] else {
                throw TourAssetTransferError.sourceMissing(descriptor.assetID)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw TourAssetTransferError.sourceSizeUnavailable(descriptor.assetID)
            }
            let actualLength = size.uint64Value
            guard actualLength == descriptor.byteLength else {
                throw TourAssetTransferError.sourceLengthMismatch(
                    assetID: descriptor.assetID,
                    expected: descriptor.byteLength,
                    actual: actualLength
                )
            }
            let actualHash = try sha256(of: url)
            guard actualHash == descriptor.sha256 else {
                throw TourAssetTransferError.sourceChecksumMismatch(
                    assetID: descriptor.assetID,
                    expected: descriptor.sha256,
                    actual: actualHash
                )
            }
            result[descriptor.sha256] = GuideSource(descriptor: descriptor, url: url)
        }
        return result
    }

    @concurrent
    private static func readChunk(
        _ url: URL,
        hash: String,
        offset: UInt64,
        count: Int
    ) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { fputs("Asset transfer: close failed (\(String(describing: type(of: error))))\n", stderr) }
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw TourAssetTransferError.shortRead(hash: hash, expected: count, actual: data.count)
        }
        return data
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { fputs("Asset transfer: close failed (\(String(describing: type(of: error))))\n", stderr) }
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
