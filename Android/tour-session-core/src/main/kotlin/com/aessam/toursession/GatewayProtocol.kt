package com.aessam.toursession

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

object GatewayProtocol {
    const val PORT = 50_104
    const val MAXIMUM_DESCRIPTOR_SIZE = 4_096
    const val ENROLLMENT_LIFETIME_MILLISECONDS = 120_000L
    const val HEARTBEAT_MILLISECONDS = 1_000L
    const val HEARTBEAT_TIMEOUT_MILLISECONDS = 3_000
    const val FORWARDED_ADMISSION_LIMIT = 4
    const val AUDIO_RESIDENCE_MILLISECONDS = 50L
}

enum class GatewayPairingRole(val wire: Int) { OFFER(1), RESPONSE(2) }

/** Public enrollment data only. No session credential or private key belongs in this record. */
data class GatewayPairingMessage(
    val role: GatewayPairingRole,
    val pairingID: UUID,
    val roomID: UUID,
    val guideID: UUID,
    val expiresAtMilliseconds: Long,
    val certificateFingerprint: ByteArray,
    val guideKeyFingerprint: ByteArray,
    val offerCertificateFingerprint: ByteArray,
    val host: String,
    val port: Int,
) {
    fun validate(nowMilliseconds: Long) {
        validateShape()
        require(nowMilliseconds >= 0)
        require(expiresAtMilliseconds > nowMilliseconds &&
            expiresAtMilliseconds - nowMilliseconds <= GatewayProtocol.ENROLLMENT_LIFETIME_MILLISECONDS) { "Enrollment expired or clock invalid" }
    }

    private fun validateShape() {
        require(listOf(pairingID, roomID, guideID).none { it == UUID(0, 0) }) { "Empty gateway identity" }
        require(expiresAtMilliseconds > 0 && certificateFingerprint.size == 32 &&
            guideKeyFingerprint.size == 32 && offerCertificateFingerprint.size == 32)
        require(host.toByteArray(Charsets.UTF_8).size <= 255)
        when (role) {
            GatewayPairingRole.OFFER -> {
                require(host.isNotEmpty() && port == GatewayProtocol.PORT)
                require(host.none { it.isWhitespace() || it.isISOControl() })
                require(MessageDigest.isEqual(certificateFingerprint, offerCertificateFingerprint))
            }
            GatewayPairingRole.RESPONSE -> require(host.isEmpty() && port == 0)
        }
    }

    fun validateResponse(response: GatewayPairingMessage, nowMilliseconds: Long) {
        validate(nowMilliseconds); response.validate(nowMilliseconds)
        require(role == GatewayPairingRole.OFFER && response.role == GatewayPairingRole.RESPONSE)
        require(pairingID == response.pairingID && roomID == response.roomID && guideID == response.guideID &&
            expiresAtMilliseconds == response.expiresAtMilliseconds &&
            MessageDigest.isEqual(guideKeyFingerprint, response.guideKeyFingerprint) &&
            MessageDigest.isEqual(certificateFingerprint, response.offerCertificateFingerprint) &&
            !MessageDigest.isEqual(certificateFingerprint, response.certificateFingerprint)) { "Response belongs to a different enrollment" }
    }

    fun encode(): ByteArray {
        validateShape()
        val hostBytes = host.toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocate(160 + hostBytes.size).apply {
            putInt(0x47485031); put(role.wire.toByte()); putUUID(pairingID); putUUID(roomID); putUUID(guideID)
            putLong(expiresAtMilliseconds); put(certificateFingerprint); put(guideKeyFingerprint)
            put(offerCertificateFingerprint); put(hostBytes.size.toByte()); put(hostBytes); putShort(port.toShort())
        }.array()
    }

    fun qrText(): String = "goh-hub:1:" + Base64.getUrlEncoder().withoutPadding().encodeToString(encode())

    companion object {
        fun decode(bytes: ByteArray): GatewayPairingMessage {
            require(bytes.size in 160..415)
            val data = ByteBuffer.wrap(bytes)
            require(data.int == 0x47485031)
            val roleValue = data.get().toInt()
            val role = GatewayPairingRole.entries.single { it.wire == roleValue }
            val pairing = data.getUUID(); val room = data.getUUID(); val guide = data.getUUID()
            val expiry = data.long; val certificate = ByteArray(32).also(data::get)
            val guideKey = ByteArray(32).also(data::get); val offer = ByteArray(32).also(data::get)
            val hostLength = data.get().toInt() and 255
            require(data.remaining() == hostLength + 2)
            val hostBytes = ByteArray(hostLength).also(data::get)
            val host = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(hostBytes)).toString()
            return GatewayPairingMessage(role, pairing, room, guide, expiry, certificate, guideKey, offer, host,
                data.short.toInt() and 65535).also { it.validateShape() }
        }
        fun fromQR(text: String): GatewayPairingMessage {
            require(text.startsWith("goh-hub:1:") && text.length <= 570)
            val encoded = text.removePrefix("goh-hub:1:")
            require(encoded.isNotEmpty() && encoded.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' })
            return decode(Base64.getUrlDecoder().decode(encoded)).also { require(it.qrText() == text) }
        }
    }
}

enum class GatewayLane(val wire: Int, val localPort: Int?) {
    HUB_CONTROL(0, null), REALTIME(1, 50_000), CONTROL(2, 50_001), ASSET(3, 50_002), ADMISSION(4, 50_003);
    companion object { fun fromNearby(lane: NearbyLaneRequest.Lane): GatewayLane = when (lane) {
        NearbyLaneRequest.Lane.REALTIME -> REALTIME
        NearbyLaneRequest.Lane.CONTROL -> CONTROL
        NearbyLaneRequest.Lane.ASSET -> ASSET
        NearbyLaneRequest.Lane.ADMISSION -> ADMISSION
        NearbyLaneRequest.Lane.METADATA -> error("Metadata belongs to hub control")
    } }
}

data class GatewayLaneRequest(val pairingID: UUID, val roomID: UUID, val generation: Long, val lane: GatewayLane) {
    fun encode(): ByteArray {
        require(pairingID != UUID(0, 0) && roomID != UUID(0, 0) && generation >= 0)
        require((lane == GatewayLane.HUB_CONTROL) == (generation == 0L))
        return ByteBuffer.allocate(SIZE).putInt(0x47484c31).putUUID(pairingID).putUUID(roomID)
            .putLong(generation).put(lane.wire.toByte()).array()
    }
    companion object {
        const val SIZE = 45
        fun decode(bytes: ByteArray): GatewayLaneRequest {
            require(bytes.size == SIZE)
            val data = ByteBuffer.wrap(bytes); require(data.int == 0x47484c31)
            val pairingID = data.getUUID(); val roomID = data.getUUID(); val generation = data.long
            val laneValue = data.get().toInt()
            val result = GatewayLaneRequest(pairingID, roomID, generation,
                GatewayLane.entries.single { it.wire == laneValue })
            result.encode(); return result
        }
    }
}

data class GatewayRoomDescriptor(val generation: Long, val recordRevision: Long,
    val record: BluetoothRoomRecord, val guidePublicKey: ByteArray) {
    fun encode(): ByteArray {
        require(generation > 0 && recordRevision > 0 && record.admissionVersion == 2)
        require(record.roomID != UUID(0, 0) && record.guideID != UUID(0, 0))
        require(guidePublicKey.size == 65 && guidePublicKey[0] == 4.toByte())
        val room = record.encode()
        return ByteBuffer.allocate(22 + room.size + 65).putInt(0x47484431).putLong(generation)
            .putLong(recordRevision).putShort(room.size.toShort()).put(room).put(guidePublicKey).array()
    }
    fun validate(offer: GatewayPairingMessage) {
        encode()
        require(record.roomID == offer.roomID && record.guideID == offer.guideID &&
            MessageDigest.isEqual(MessageDigest.getInstance("SHA-256").digest(guidePublicKey), offer.guideKeyFingerprint)) { "Guide identity changed" }
    }
    companion object {
        fun decode(bytes: ByteArray): GatewayRoomDescriptor {
            require(bytes.size in 127..526)
            val data = ByteBuffer.wrap(bytes); require(data.int == 0x47484431)
            val generation = data.long; val revision = data.long; val length = data.short.toInt() and 65535
            require(data.remaining() == length + 65)
            return GatewayRoomDescriptor(generation, revision, BluetoothRoomRecord.decode(ByteArray(length).also(data::get)),
                ByteArray(65).also(data::get)).also { it.encode() }
        }
    }
}

private fun ByteBuffer.putUUID(value: UUID): ByteBuffer = putLong(value.mostSignificantBits).putLong(value.leastSignificantBits)
private fun ByteBuffer.getUUID(): UUID = UUID(long, long)
