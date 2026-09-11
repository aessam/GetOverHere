import Foundation

/// Optional GATT endpoint metadata, never authority. GOD1 and the authenticated
/// application handshake still run on every channel. Metadata shares admission's
/// transient endpoint; the three persistent lanes use distinct native endpoints.
public struct BluetoothLanePSMs: Equatable, Sendable {
    public static let size = 12
    public let admission: UInt16
    public let realtime: UInt16
    public let control: UInt16
    public let asset: UInt16

    public init(admission: UInt16, realtime: UInt16, control: UInt16, asset: UInt16) throws {
        let values = [admission, realtime, control, asset]
        guard !values.contains(0), Set(values).count == 4 else { throw RoomAdmissionError.invalidMessage }
        self.admission = admission
        self.realtime = realtime
        self.control = control
        self.asset = asset
    }

    public func psm(for lane: NearbyLaneRequest.Lane) -> UInt16 {
        switch lane {
        case .metadata, .admission: admission
        case .realtime: realtime
        case .control: control
        case .asset: asset
        }
    }

    public func encode() -> Data {
        Data("GOL1".utf8) + Data([admission, realtime, control, asset].flatMap {
            [UInt8($0 >> 8), UInt8($0 & 255)]
        })
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == size, bytes.prefix(4).elementsEqual("GOL1".utf8) else {
            throw RoomAdmissionError.invalidMessage
        }
        func value(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        return try Self(admission: value(4), realtime: value(6), control: value(8), asset: value(10))
    }
}
