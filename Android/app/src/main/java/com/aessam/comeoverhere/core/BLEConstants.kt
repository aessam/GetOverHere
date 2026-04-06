package com.aessam.comeoverhere.core

import java.util.UUID

/**
 * Shared BLE UUIDs — must be identical to iOS BLEConstants.
 * Service UUID is used for advertising/scanning.
 * Characteristics are used for data exchange within the GATT server.
 */
object BLEConstants {
    /** Primary service UUID advertised by all ComeOverHere/GetOverHere peers. */
    val SERVICE_UUID: UUID = UUID.fromString("A1B2C3D4-0001-0000-0000-000000000000")

    /** Command write characteristic — central writes JSON BLECommand to peripheral. */
    val COMMAND_WRITE_UUID: UUID = UUID.fromString("A1B2C3D4-0002-0000-0000-000000000000")

    /** Command notify characteristic — peripheral pushes JSON BLECommand to subscribed centrals. */
    val COMMAND_NOTIFY_UUID: UUID = UUID.fromString("A1B2C3D4-0003-0000-0000-000000000000")

    /** Peer info characteristic — readable, returns "id|displayName|platform" */
    val PEER_INFO_UUID: UUID = UUID.fromString("A1B2C3D4-0004-0000-0000-000000000000")

    /** Standard Client Characteristic Configuration Descriptor for enabling notifications. */
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
}
