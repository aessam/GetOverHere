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

    init(transport: SessionAssetTransport, cache: TourAssetCache) {
        self.transport = transport
        self.cache = cache
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
            transport.startGuide()
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
        transport.startGuide()
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
        case .connected, .disconnected:
            break
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

        var requestedHashes = Set<String>()
        for descriptor in manifest.assets {
            if let ready = try await cache.readyURL(
                sha256: descriptor.sha256,
                expectedLength: descriptor.byteLength
            ) {
                markReady(hash: descriptor.sha256, url: ready)
                if requestedHashes.insert(descriptor.sha256).inserted {
                    sendStatus(
                        hash: descriptor.sha256,
                        status: .ready,
                        byteLength: descriptor.byteLength,
                        detail: ""
                    )
                }
            } else if requestedHashes.insert(descriptor.sha256).inserted {
                let offset = try await cache.resumeOffset(
                    sha256: descriptor.sha256,
                    expectedLength: descriptor.byteLength
                )
                try sendRequest(hash: descriptor.sha256, offset: offset)
            }
        }
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

        switch try await cache.ingest(chunk) {
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
        }
    }

    private func sendRequest(hash: String, offset: UInt64) throws {
        let request = try AssetRequestPayload(sha256: hash, offset: offset)
        transport.send(kind: .assetRequest, payload: try request.encode(), to: nil)
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
