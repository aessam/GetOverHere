import Darwin
import Foundation
import TourSessionCore

/// A far guest's lanes go through this island bridge instead of the guide (ADR-081 P4).
nonisolated struct RelayRoute: Equatable, Sendable {
    let host: RelayHostAdvert
    let guideID: UUID
}

/**
 Far-guest side of the ADR-083 relay lane handshake (mirrors Android `RelayLaneClient`). The challenge and welcome are
 bridge-sealed (not GOS1); the welcome must carry the guide-signed assignment naming exactly `RelayRoute.host`. After
 it, every realtime/control frame is a guide frame the guest verifies with its pinned key as usual.
 */
nonisolated enum RelayLaneClient {
    /// The bridge's proof or assignment did not match: rediscover the island, never a credential failure.
    struct RelayRouteRejected: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "Island bridge rejected: \(reason)" }
    }

    static let guideSignedMagic = Data("GOS1".utf8)

    static func isGuideSigned(_ frame: Data) -> Bool { frame.prefix(4) == guideSignedMagic }

    static func handshake(fd: Int32, route: RelayRoute, lane: SessionLane, credential: SessionCredential, sessionID: UUID,
                          participantID: UUID, platform: ParticipantPlatform, capabilities: UInt32, displayName: String,
                          verifier: GuideFrameVerifier, maximumFrameSize: Int,
                          nowMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)) throws -> BridgeAssignmentPayload {
        let opener = SessionFrameOpener(credential: credential)
        func open(_ frame: Data) throws -> SessionEnvelope {
            guard case let .opened(envelope) = try opener.open(SealedSessionEnvelope.decode(frame)) else {
                throw RelayRouteRejected(reason: "duplicate handshake frame")
            }
            return envelope
        }
        let challengeEnvelope = try open(try readFrame(fd: fd, maximum: maximumFrameSize))
        guard challengeEnvelope.sessionID == sessionID, challengeEnvelope.kind == .authChallenge,
              challengeEnvelope.senderID == route.host.hostID else { throw RelayRouteRejected(reason: "unexpected challenge") }
        let challenge = try AuthChallengePayload.decode(challengeEnvelope.payload)
        guard challenge.requestedLane == lane else { throw RelayRouteRejected(reason: "challenge for the wrong lane") }
        let context = RelayLaneContext(sessionID: sessionID, guideID: route.guideID, host: route.host,
                                       participantID: participantID, lane: lane)
        let clientNonce = SessionAuthenticator.randomNonce()
        let proof = try RelayLaneAuthenticator.guestProof(credential: credential, context: context,
            challengeNonce: challenge.challengeNonce, clientNonce: clientNonce, role: .guest, platform: platform,
            capabilities: capabilities, displayName: displayName)
        let hello = try HelloPayload(role: .guest, platform: platform, capabilities: capabilities, displayName: displayName,
                                     requestedLane: lane, clientNonce: clientNonce, credentialProof: proof)
        let helloEnvelope = try SessionEnvelope(lane: .control, kind: .hello, sequence: 0, sessionID: sessionID,
                                                senderID: participantID, payload: hello.encode())
        try writeFrame(fd: fd, SessionFrameSealer(credential: credential).seal(helloEnvelope, streamID: UUID()).encode())
        let welcomeEnvelope = try open(try readFrame(fd: fd, maximum: maximumFrameSize))
        guard welcomeEnvelope.sessionID == sessionID, welcomeEnvelope.kind == .welcome,
              welcomeEnvelope.senderID == route.host.hostID else { throw RelayRouteRejected(reason: "unexpected welcome") }
        do {
            return try RelayWelcomePayload.decode(welcomeEnvelope.payload).verify(credential: credential, context: context,
                challengeNonce: challenge.challengeNonce, clientNonce: clientNonce, guide: verifier, nowMilliseconds: nowMilliseconds)
        } catch {
            throw RelayRouteRejected(reason: String(describing: error))
        }
    }

    private static func readFrame(fd: Int32, maximum: Int) throws -> Data {
        let header = try readExact(fd: fd, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximum) else { throw RelayRouteRejected(reason: "invalid frame length \(length)") }
        return try readExact(fd: fd, count: Int(length))
    }

    private static func readExact(fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard received > 0 else { throw RelayRouteRejected(reason: "bridge closed the lane") }
            offset += received
        }
        return Data(bytes)
    }

    private static func writeFrame(fd: Int32, _ data: Data) throws {
        var length = UInt32(data.count).bigEndian
        let framed = Data(bytes: &length, count: 4) + data
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < framed.count {
                let written = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), framed.count - offset, 0)
                guard written > 0 else { throw RelayRouteRejected(reason: "bridge closed the lane") }
                offset += written
            }
        }
    }
}
