import CoreBluetooth

enum BLEConstants {
    static let serviceUUID = CBUUID(string: "A1B2C3D4-0001-0000-0000-000000000000")
    /// Write commands to the remote device's GATT server
    static let commandWriteUUID = CBUUID(string: "A1B2C3D4-0002-0000-0000-000000000000")
    /// Receive commands via notifications from the remote device
    static let commandNotifyUUID = CBUUID(string: "A1B2C3D4-0003-0000-0000-000000000000")
    /// Read the peer's identity: "id|displayName|platform"
    static let peerInfoUUID = CBUUID(string: "A1B2C3D4-0004-0000-0000-000000000000")
}
