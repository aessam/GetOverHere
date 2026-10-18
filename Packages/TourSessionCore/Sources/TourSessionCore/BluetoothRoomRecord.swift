import Foundation

/// A prepared tour the guide will present (ADR-080 DSCN-2). Guests holding a pack with this ID show
/// "Tour ready" before joining; readiness itself is still decided by the session manifest's hashes.
public struct TourPackAdvert: Equatable, Sendable {
    public let packID: UUID
    public let manifestVersion: UInt64
    public init(packID: UUID, manifestVersion: UInt64) {
        self.packID = packID; self.manifestVersion = manifestVersion
    }
}

/// Public discovery metadata only. No address, credential, participant location, or commands.
/// Flags: 1 Android guide, 2 locked, 4 a `TourPackAdvert` (16-byte pack ID + u64 version) follows the name.
public struct BluetoothRoomRecord: Equatable, Sendable {
    public let roomID: UUID
    public let guideID: UUID
    public let name: String
    public let isAndroid: Bool
    public let isLocked: Bool
    public let admissionVersion: Int
    public let pack: TourPackAdvert?

    public static let maximumLength = 439
    static let packAdvertLength = 24

    public init(roomID: UUID, guideID: UUID, name: String, isAndroid: Bool, isLocked: Bool, admissionVersion: Int = 1,
                pack: TourPackAdvert? = nil) {
        self.roomID = roomID; self.guideID = guideID; self.name = name
        self.isAndroid = isAndroid; self.isLocked = isLocked
        self.admissionVersion = admissionVersion
        self.pack = pack
    }

    public enum InvalidRecord: Error { case malformed }

    public func encode() throws -> Data {
        let text = Array(name.utf8)
        let packLength = pack == nil ? 0 : Self.packAdvertLength
        guard !text.isEmpty, text.count <= 400, 39 + text.count + packLength <= Self.maximumLength,
              (1...2).contains(admissionVersion) else { throw InvalidRecord.malformed }
        var room = roomID.uuid
        var guide = guideID.uuid
        var data = Data((admissionVersion == 1 ? "GOR1" : "GOR2").utf8)
        data.append((isAndroid ? 1 : 0) | (isLocked ? 2 : 0) | (pack == nil ? 0 : 4))
        withUnsafeBytes(of: &room) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &guide) { data.append(contentsOf: $0) }
        data.append(UInt8(text.count >> 8)); data.append(UInt8(text.count & 255))
        data.append(contentsOf: text)
        if let pack {
            var packID = pack.packID.uuid
            withUnsafeBytes(of: &packID) { data.append(contentsOf: $0) }
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((pack.manifestVersion >> UInt64(shift)) & 0xff)) }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard (40...439).contains(bytes.count), Array(bytes[0..<3]) == Array("GOR".utf8),
              bytes[3] == 0x31 || bytes[3] == 0x32,
              bytes[4] <= 7 else { throw InvalidRecord.malformed }
        let packLength = bytes[4] & 4 != 0 ? Self.packAdvertLength : 0
        let length = Int(bytes[37]) * 256 + Int(bytes[38])
        guard length == bytes.count - 39 - packLength,
              let name = String(bytes: bytes[39 ..< 39 + length], encoding: .utf8), !name.isEmpty else {
            throw InvalidRecord.malformed
        }
        func uuid(_ offset: Int) -> UUID {
            var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes[offset..<(offset + 16)]) }
            return UUID(uuid: value)
        }
        let pack = packLength == 0 ? nil : TourPackAdvert(
            packID: uuid(39 + length),
            manifestVersion: bytes[(39 + length + 16)...].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        return Self(roomID: uuid(5), guideID: uuid(21), name: name,
                    isAndroid: bytes[4] & 1 != 0, isLocked: bytes[4] & 2 != 0, admissionVersion: Int(bytes[3] - 0x30),
                    pack: pack)
    }
}
