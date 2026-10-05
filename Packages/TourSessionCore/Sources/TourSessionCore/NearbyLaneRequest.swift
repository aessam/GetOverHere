import Foundation

/// Public connection selector, not admission. Every selected application lane still
/// performs its existing authenticated handshake. Never accepts arbitrary ports/hosts.
public struct NearbyLaneRequest: Equatable, Sendable {
    public enum Lane: UInt8, CaseIterable, Sendable {
        case metadata = 0, realtime, control, asset, admission

        public var localPort: UInt16? {
            switch self {
            case .metadata: nil
            case .realtime: 50_000
            case .control: 50_001
            case .asset: 50_002
            case .admission: 50_003
            }
        }
    }

    public static let size = 21
    public static let servicePort: UInt16 = 50_004
    public static let metadataRoomID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    public let lane: Lane
    public let roomID: UUID

    public init(lane: Lane, roomID: UUID) throws {
        guard (lane == .metadata) == (roomID == Self.metadataRoomID) else {
            throw RoomAdmissionError.invalidMessage
        }
        self.lane = lane
        self.roomID = roomID
    }

    public func encode() -> Data {
        var id = roomID.uuid
        return Data("GOD1".utf8) + Data([lane.rawValue]) + withUnsafeBytes(of: &id) { Data($0) }
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == size, bytes.prefix(4).elementsEqual("GOD1".utf8),
              let lane = Lane(rawValue: bytes[4]) else { throw RoomAdmissionError.invalidMessage }
        let id = UUID(uuid: (bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                             bytes[13], bytes[14], bytes[15], bytes[16], bytes[17], bytes[18], bytes[19], bytes[20]))
        return try Self(lane: lane, roomID: id)
    }
}
