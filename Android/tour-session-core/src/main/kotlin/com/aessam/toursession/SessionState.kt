package com.aessam.toursession

import java.util.UUID

data class PresentationSnapshotPayload(
    val stateVersion: Long,
    val deckID: UUID,
    val currentSlideID: String?,
    val isVisible: Boolean,
    val effectiveAtMilliseconds: Long,
) {
    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUInt64(stateVersion)
        writer.appendUuid(deckID)
        writer.appendUInt8(if (isVisible) 1 else 0)
        writer.appendUInt64(effectiveAtMilliseconds)
        writer.appendString(currentSlideID ?: "")
        return writer.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray): PresentationSnapshotPayload {
            val reader = BinaryReader(data)
            val stateVersion = reader.readUInt64()
            val deckID = reader.readUuid()
            val visibleRaw = reader.readUInt8()
            if (visibleRaw !in 0..1) throw SessionProtocolException("invalid boolean $visibleRaw")
            val effectiveAt = reader.readUInt64()
            val slide = reader.readString()
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return PresentationSnapshotPayload(
                stateVersion,
                deckID,
                slide.ifEmpty { null },
                visibleRaw == 1,
                effectiveAt,
            )
        }
    }
}

enum class TourVisualMode(val rawValue: Int) {
    SLIDES(1),
    MAP(2),
    POINTER(3);

    companion object {
        fun fromRaw(raw: Int): TourVisualMode = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("invalid visual mode $raw")
    }
}

data class VisualFocusSnapshotPayload(
    val stateVersion: Long,
    val mode: TourVisualMode,
) {
    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUInt64(stateVersion)
        writer.appendUInt8(mode.rawValue)
        return writer.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray): VisualFocusSnapshotPayload {
            val reader = BinaryReader(data)
            val stateVersion = reader.readUInt64()
            val mode = TourVisualMode.fromRaw(reader.readUInt8())
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return VisualFocusSnapshotPayload(stateVersion, mode)
        }
    }
}

enum class BearingReference(val rawValue: Int) {
    MAGNETIC(1),
    TRUE_NORTH(2);

    companion object {
        fun fromRaw(raw: Int): BearingReference = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("invalid bearing reference $raw")
    }
}

data class BearingSnapshotPayload(
    val stateVersion: Long,
    val reference: BearingReference,
    val bearingMilliDegrees: Long,
    val isVisible: Boolean,
) {
    init {
        if (bearingMilliDegrees !in 0L..359_999L) {
            throw SessionProtocolException("invalid bearing $bearingMilliDegrees millidegrees")
        }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUInt64(stateVersion)
        writer.appendUInt8(reference.rawValue)
        writer.appendUInt32(bearingMilliDegrees)
        writer.appendUInt8(if (isVisible) 1 else 0)
        return writer.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray): BearingSnapshotPayload {
            val reader = BinaryReader(data)
            val stateVersion = reader.readUInt64()
            val reference = BearingReference.fromRaw(reader.readUInt8())
            val bearing = reader.readUInt32()
            val visibleRaw = reader.readUInt8()
            if (visibleRaw !in 0..1) throw SessionProtocolException("invalid boolean $visibleRaw")
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return BearingSnapshotPayload(stateVersion, reference, bearing, visibleRaw == 1)
        }
    }
}

data class TargetSnapshotPayload(
    val stateVersion: Long,
    val targetID: UUID,
    val latitudeE7: Int,
    val longitudeE7: Int,
    val label: String,
    val isVisible: Boolean,
) {
    init {
        if (latitudeE7 !in LATITUDE_RANGE_E7) {
            throw SessionProtocolException("invalid latitude E7 $latitudeE7")
        }
        if (longitudeE7 !in LONGITUDE_RANGE_E7) {
            throw SessionProtocolException("invalid longitude E7 $longitudeE7")
        }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUInt64(stateVersion)
        writer.appendUuid(targetID)
        writer.appendInt32(latitudeE7)
        writer.appendInt32(longitudeE7)
        writer.appendUInt8(if (isVisible) 1 else 0)
        writer.appendString(label)
        return writer.toByteArray()
    }

    companion object {
        val LATITUDE_RANGE_E7 = -900_000_000..900_000_000
        val LONGITUDE_RANGE_E7 = -1_800_000_000..1_800_000_000

        fun decode(data: ByteArray): TargetSnapshotPayload {
            val reader = BinaryReader(data)
            val stateVersion = reader.readUInt64()
            val targetID = reader.readUuid()
            val latitudeE7 = reader.readInt32()
            val longitudeE7 = reader.readInt32()
            val visibleRaw = reader.readUInt8()
            if (visibleRaw !in 0..1) throw SessionProtocolException("invalid boolean $visibleRaw")
            val label = reader.readString()
            if (reader.remaining != 0) {
                throw SessionProtocolException("payload has ${reader.remaining} trailing bytes")
            }
            return TargetSnapshotPayload(
                stateVersion,
                targetID,
                latitudeE7,
                longitudeE7,
                label,
                visibleRaw == 1,
            )
        }
    }
}
