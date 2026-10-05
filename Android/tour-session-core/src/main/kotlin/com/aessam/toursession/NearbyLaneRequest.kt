package com.aessam.toursession

import java.nio.ByteBuffer
import java.util.UUID

/** Public selector only. The selected lane must still authenticate; no arbitrary destinations. */
data class NearbyLaneRequest(val lane: Lane, val roomID: UUID) {
    enum class Lane(val wireValue: Int, val localPort: Int?) {
        METADATA(0, null), REALTIME(1, 50_000), CONTROL(2, 50_001), ASSET(3, 50_002), ADMISSION(4, 50_003),
    }

    init { require((lane == Lane.METADATA) == (roomID == METADATA_ROOM_ID)) { "Invalid nearby room selector" } }

    fun encode(): ByteArray = ByteBuffer.allocate(SIZE).apply {
        putInt(0x474f4431)
        put(lane.wireValue.toByte())
        putLong(roomID.mostSignificantBits)
        putLong(roomID.leastSignificantBits)
    }.array()

    companion object {
        const val SIZE = 21
        const val SERVICE_PORT = 50_004
        val METADATA_ROOM_ID = UUID(0, 0)

        fun decode(bytes: ByteArray): NearbyLaneRequest {
            require(bytes.size == SIZE) { "Invalid nearby selector length" }
            val buffer = ByteBuffer.wrap(bytes)
            require(buffer.int == 0x474f4431) { "Unsupported nearby selector" }
            val raw = buffer.get().toInt() and 255
            val lane = requireNotNull(Lane.entries.firstOrNull { it.wireValue == raw }) { "Invalid nearby lane" }
            return NearbyLaneRequest(lane, UUID(buffer.long, buffer.long))
        }
    }
}
