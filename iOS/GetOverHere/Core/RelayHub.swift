import Foundation
import os
import TourSessionCore

/// One island peer's outbound side; enqueue must never block (ADR-039).
nonisolated protocol RelayChildWriter: AnyObject, Sendable {
    /// False when the peer cannot take the frame (overloaded or gone); the hub then drops it.
    func enqueue(_ frame: Data) -> Bool
    func close()
}

/**
 The bridge's fan-out of verified guide frames to its island (ADR-081 P4, mirrors Android `RelayHub`). Every GOS1
 frame from the bridge's upstream lanes goes through `RelayForwarder` (verify, dedup, residence bound); forwarded
 frames go unchanged to each island peer of that lane. Control peers get the cached snapshots first, asset peers the
 newest tour manifest. The hub tracks the guide's newest `bridgeAssignment`: it must name this bridge, or the island
 is torn down.
 */
nonisolated final class RelayHub: @unchecked Sendable {
    struct Counters: Equatable, Sendable {
        var forwarded = 0, duplicates = 0, expired = 0, conflicts = 0, dropped = 0
    }

    private let bridgeID: UUID
    private let verifier: GuideFrameVerifier
    private let credential: SessionCredential
    /// A guide frame failed verification or conflicted: drop that upstream route and fail over (D7).
    private let onRouteFault: @Sendable (SessionLane, String) -> Void
    /// The guide assigned another bridge (or a newer generation elsewhere): close the island (P3 seam).
    private let onIslandRevoked: @Sendable (BridgeAssignmentPayload) -> Void
    private let lock = NSLock()
    private var forwarder: RelayForwarder
    private var children: [SessionLane: [RelayChildWriter]] = [:]
    private var manifestFrame: Data?
    private var currentAssignmentFrame: Data?
    private var currentAssignment: BridgeAssignmentPayload?
    /// Highest assignment generation seen; never decreases, so a replayed older assignment cannot reinstate a host.
    private var generationWatermark: UInt64?
    private var currentCounters = Counters()

    init(bridgeID: UUID, verifier: GuideFrameVerifier, credential: SessionCredential,
         onRouteFault: @escaping @Sendable (SessionLane, String) -> Void,
         onIslandRevoked: @escaping @Sendable (BridgeAssignmentPayload) -> Void) {
        self.bridgeID = bridgeID
        self.verifier = verifier
        self.credential = credential
        self.onRouteFault = onRouteFault
        self.onIslandRevoked = onIslandRevoked
        forwarder = RelayForwarder(verifier: verifier)
    }

    var assignment: BridgeAssignmentPayload? { lock.withLock { currentAssignment } }
    var assignmentFrame: Data? { lock.withLock { currentAssignmentFrame } }
    /// The assignment and its signed frame read together (the lane handshake needs both to agree).
    var assigned: (frame: Data, payload: BridgeAssignmentPayload)? {
        lock.withLock { currentAssignmentFrame.flatMap { frame in currentAssignment.map { (frame, $0) } } }
    }
    var counters: Counters { lock.withLock { currentCounters } }

    /// Every GOS1 frame the bridge's upstream lanes deliver.
    func onUpstreamFrame(lane: SessionLane, frame: Data, receivedAtMilliseconds: UInt64, nowMilliseconds: UInt64) {
        var revoked: BridgeAssignmentPayload?
        var fault: String?
        lock.lock()
        defer {
            lock.unlock()
            if let fault { onRouteFault(lane, fault) }
            if let revoked { onIslandRevoked(revoked) }
        }
        if lane == .asset {
            // Only the manifest is relayed; chunks answer the bridge's own requests and stay out of the dedup window.
            do {
                guard try verifier.verify(frame).kind == .tourPackManifest else { return }
            } catch {
                fault = "guide frame rejected: \(error)"
                return
            }
        }
        let decision: RelayForwarder.Decision
        do {
            decision = try forwarder.admit(frame, receivedAtMilliseconds: receivedAtMilliseconds, nowMilliseconds: nowMilliseconds)
        } catch {
            fault = "guide frame rejected: \(error)"
            return
        }
        switch decision {
        case .duplicate: currentCounters.duplicates += 1
        case .expired: currentCounters.expired += 1
        case .conflict:
            currentCounters.conflicts += 1
            fault = "guide frame identity reused with different bytes"
        case .forward:
            // Lane and kind come from the guide-signed envelope, never from the socket that delivered it.
            guard let sealed = try? verifier.verify(frame) else { return }
            guard sealed.lane == lane else {
                fault = "guide \(sealed.lane) frame arrived on the \(lane) lane"
                return
            }
            if lane == .asset { manifestFrame = frame }
            currentCounters.forwarded += 1
            if sealed.kind == .bridgeAssignment { revoked = observeAssignment(sealed, frame: frame) }
            fanOut(lane: lane, frame: frame)
        }
    }

    /// Registers an island peer after its relay lane handshake; it gets the cached state for its lane first.
    func attach(lane: SessionLane, writer: RelayChildWriter) {
        lock.withLock {
            let replay: [Data] = switch lane {
            case .control: forwarder.snapshotFrames
            case .asset: manifestFrame.map { [$0] } ?? []
            case .realtime: []
            }
            for frame in replay where !writer.enqueue(frame) {
                writer.close()
                currentCounters.dropped += 1
                return
            }
            children[lane, default: []].append(writer)
        }
    }

    func detach(lane: SessionLane, writer: RelayChildWriter) {
        lock.withLock { children[lane]?.removeAll { $0 === writer } }
    }

    func closeIsland() {
        let closing = lock.withLock {
            let all = children.values.flatMap { $0 }
            children.removeAll()
            return all
        }
        closing.forEach { $0.close() }
    }

    /// Called under the lock.
    private func fanOut(lane: SessionLane, frame: Data) {
        guard let peers = children[lane] else { return }
        var kept: [RelayChildWriter] = []
        for peer in peers {
            if peer.enqueue(frame) {
                kept.append(peer)
            } else {
                peer.close()
                currentCounters.dropped += 1
            }
        }
        children[lane] = kept
    }

    /// Called under the lock with an already verified frame; returns the assignment that revoked this bridge.
    private func observeAssignment(_ sealed: SealedSessionEnvelope, frame: Data) -> BridgeAssignmentPayload? {
        guard case let .opened(envelope)? = try? SessionFrameOpener(credential: credential).open(sealed),
              let value = try? BridgeAssignmentPayload.decode(envelope.payload) else { return nil }
        if let watermark = generationWatermark, value.generation < watermark { return nil }
        generationWatermark = value.generation
        if value.bridgeID == bridgeID {
            currentAssignment = value
            currentAssignmentFrame = frame
            return nil
        }
        currentAssignment = nil
        currentAssignmentFrame = nil
        let all = children.values.flatMap { $0 }
        children.removeAll()
        all.forEach { $0.close() }
        return value
    }
}
