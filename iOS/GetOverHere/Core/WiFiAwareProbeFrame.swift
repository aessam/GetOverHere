import Foundation

nonisolated struct WiFiAwareProbeFrame: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        case hello = 1
        case probe = 2
        case echo = 3
    }

    enum DecodeError: Error, Equatable {
        case headerTooShort
        case invalidMagic
        case unsupportedVersion(UInt8)
        case invalidKind(UInt8)
        case invalidPayloadLength(expected: Int, actual: Int)
    }

    static let magic: UInt32 = 0x474F4831
    static let version: UInt8 = 1
    static let headerSize = 28

    let kind: Kind
    let sequence: UInt64
    let sentAtNanoseconds: UInt64
    let payload: Data

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.appendBigEndian(Self.magic)
        data.append(Self.version)
        data.append(kind.rawValue)
        data.append(contentsOf: [0, 0])
        data.appendBigEndian(sequence)
        data.appendBigEndian(sentAtNanoseconds)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count >= headerSize else { throw DecodeError.headerTooShort }

        let magic = data.readBigEndianUInt32(at: 0)
        guard magic == Self.magic else { throw DecodeError.invalidMagic }

        let version = data[4]
        guard version == Self.version else { throw DecodeError.unsupportedVersion(version) }

        let kindValue = data[5]
        guard let kind = Kind(rawValue: kindValue) else { throw DecodeError.invalidKind(kindValue) }

        let sequence = data.readBigEndianUInt64(at: 8)
        let sentAtNanoseconds = data.readBigEndianUInt64(at: 16)
        let payloadLength = Int(data.readBigEndianUInt32(at: 24))
        let actualPayloadLength = data.count - headerSize
        guard payloadLength == actualPayloadLength else {
            throw DecodeError.invalidPayloadLength(expected: payloadLength, actual: actualPayloadLength)
        }

        return Self(
            kind: kind,
            sequence: sequence,
            sentAtNanoseconds: sentAtNanoseconds,
            payload: data.subdata(in: headerSize..<data.count)
        )
    }
}

private extension Data {
    nonisolated mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    nonisolated func readBigEndianUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    nonisolated func readBigEndianUInt64(at offset: Int) -> UInt64 {
        self[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
