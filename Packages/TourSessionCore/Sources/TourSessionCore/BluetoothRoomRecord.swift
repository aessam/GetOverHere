import Foundation

/// Public discovery metadata only. No address, credential, participant location, or commands.
public struct BluetoothRoomRecord: Equatable, Sendable {
    public let roomID: UUID
    public let guideID: UUID
    public let name: String
    public let isAndroid: Bool
    public let isLocked: Bool

    public init(roomID: UUID, guideID: UUID, name: String, isAndroid: Bool, isLocked: Bool) {
        self.roomID = roomID; self.guideID = guideID; self.name = name
        self.isAndroid = isAndroid; self.isLocked = isLocked
    }

    public enum InvalidRecord: Error { case malformed }

    public func encode() throws -> Data {
        let text = Array(name.utf8)
        guard !text.isEmpty, text.count <= 400 else { throw InvalidRecord.malformed }
        var room = roomID.uuid
        var guide = guideID.uuid
        var data = Data("GOR1".utf8)
        data.append((isAndroid ? 1 : 0) | (isLocked ? 2 : 0))
        withUnsafeBytes(of: &room) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &guide) { data.append(contentsOf: $0) }
        data.append(UInt8(text.count >> 8)); data.append(UInt8(text.count & 255))
        data.append(contentsOf: text)
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard (40...439).contains(bytes.count), Array(bytes[0..<4]) == Array("GOR1".utf8),
              bytes[4] <= 3 else { throw InvalidRecord.malformed }
        let length = Int(bytes[37]) * 256 + Int(bytes[38])
        guard length == bytes.count - 39,
              let name = String(bytes: bytes[39...], encoding: .utf8), !name.isEmpty else {
            throw InvalidRecord.malformed
        }
        func uuid(_ offset: Int) -> UUID {
            var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes[offset..<(offset + 16)]) }
            return UUID(uuid: value)
        }
        return Self(roomID: uuid(5), guideID: uuid(21), name: name,
                    isAndroid: bytes[4] & 1 != 0, isLocked: bytes[4] & 2 != 0)
    }
}
