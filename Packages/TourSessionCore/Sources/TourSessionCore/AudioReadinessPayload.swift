import Foundation

/// Renderer-reported readiness. This does not claim that a person can hear the speaker.
public enum AudioReadinessStatus: UInt8, CaseIterable, Sendable {
    case waiting = 1, playing = 2, interrupted = 3, failed = 4
}

/// Sent on an authenticated guest control lane. The sender UUID comes from its envelope,
/// never from a guest-supplied payload identity. Revisions increase within the room session.
public struct AudioReadinessPayload: Equatable, Sendable {
    public let status: AudioReadinessStatus
    public let revision: UInt64

    public init(status: AudioReadinessStatus, revision: UInt64) {
        self.status = status
        self.revision = revision
    }

    public func encode() -> Data {
        var bytes: [UInt8] = [1, status.rawValue]
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: revision >> shift))
        }
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard bytes.count == 10, bytes[0] == 1,
              let status = AudioReadinessStatus(rawValue: bytes[1]) else {
            throw SessionProtocolError.invalidPayloadLength(expected: 10, actual: bytes.count)
        }
        let revision = bytes.dropFirst(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Self(status: status, revision: revision)
    }
}
