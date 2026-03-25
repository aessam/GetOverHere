import CoreBluetooth

/// Shared BLE UUIDs — must match Android's BLEConstants.kt exactly.
enum BLEConstants {
    static let serviceUUID = CBUUID(string: "A1B2C3D4-0001-0000-0000-000000000000")
    static let dataWriteUUID = CBUUID(string: "A1B2C3D4-0002-0000-0000-000000000000")
    static let dataNotifyUUID = CBUUID(string: "A1B2C3D4-0003-0000-0000-000000000000")
    static let peerNameUUID = CBUUID(string: "A1B2C3D4-0004-0000-0000-000000000000")
    /// L2CAP PSM characteristic — readable, contains the PSM number for audio streaming
    static let audioPSMUUID = CBUUID(string: "A1B2C3D4-0005-0000-0000-000000000000")
}
