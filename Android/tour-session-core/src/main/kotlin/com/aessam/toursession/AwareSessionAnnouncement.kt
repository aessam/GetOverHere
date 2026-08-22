package com.aessam.toursession

import java.nio.charset.StandardCharsets
import java.util.UUID

/** Public metadata carried by the Wi-Fi Aware bootstrap connection. */
data class AwareSessionAnnouncement(
    val sessionID: UUID,
    val guideID: UUID,
    val guidePlatform: ParticipantPlatform,
    val realtimePort: Int,
    val controlPort: Int,
    val assetPort: Int,
    val channelName: String,
    val guideDisplayName: String,
) {
    init {
        require(realtimePort in 1..0xffff) { "invalid Wi-Fi Aware lane port" }
        require(controlPort in 1..0xffff) { "invalid Wi-Fi Aware lane port" }
        require(assetPort in 1..0xffff) { "invalid Wi-Fi Aware lane port" }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter(64 + channelName.length + guideDisplayName.length)
        writer.append(MAGIC)
        writer.appendUInt8(WIRE_VERSION)
        writer.appendUuid(sessionID)
        writer.appendUuid(guideID)
        writer.appendUInt8(guidePlatform.rawValue)
        writer.appendUInt16(realtimePort)
        writer.appendUInt16(controlPort)
        writer.appendUInt16(assetPort)
        writer.appendString(channelName)
        writer.appendString(guideDisplayName)
        return writer.toByteArray()
    }

    companion object {
        const val WIRE_VERSION = 1
        private val MAGIC = "GOHA".toByteArray(StandardCharsets.US_ASCII)

        fun decode(data: ByteArray): AwareSessionAnnouncement {
            val reader = BinaryReader(data)
            if (!reader.readBytes(MAGIC.size).contentEquals(MAGIC)) {
                throw SessionProtocolException("invalid GOHA magic")
            }
            val version = reader.readUInt8()
            if (version != WIRE_VERSION) {
                throw SessionProtocolException("unsupported Wi-Fi Aware version $version")
            }
            val sessionID = reader.readUuid()
            val guideID = reader.readUuid()
            val platform = ParticipantPlatform.fromRaw(reader.readUInt8())
            val realtimePort = reader.readUInt16()
            val controlPort = reader.readUInt16()
            val assetPort = reader.readUInt16()
            val channelName = reader.readString()
            val guideDisplayName = reader.readString()
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return AwareSessionAnnouncement(
                sessionID,
                guideID,
                platform,
                realtimePort,
                controlPort,
                assetPort,
                channelName,
                guideDisplayName,
            )
        }
    }
}
