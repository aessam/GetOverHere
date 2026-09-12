package com.aessam.toursession

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID

class GatewayProtocolTest {
    private val key = byteArrayOf(4) + ByteArray(64) { 7 }
    private val offer = GatewayPairingMessage(GatewayPairingRole.OFFER, UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
        121_000, ByteArray(32) { 1 }, MessageDigest.getInstance("SHA-256").digest(key), ByteArray(32) { 1 }, "10.0.0.1", 50_104)
    private val response get() = offer.copy(role = GatewayPairingRole.RESPONSE, certificateFingerprint = ByteArray(32) { 2 }, host = "", port = 0)
    @Test fun enrollmentRoundTripsAndResponseBindsEveryIdentity() {
        listOf(offer, response).forEach { value ->
            assertArrayEquals(value.encode(), GatewayPairingMessage.decode(value.encode()).encode())
            assertEquals(value.qrText(), GatewayPairingMessage.fromQR(value.qrText()).qrText())
        }
        offer.validateResponse(response, 1_000)
        listOf(response.copy(pairingID = UUID.randomUUID()), response.copy(roomID = UUID.randomUUID()),
            response.copy(guideID = UUID.randomUUID()), response.copy(expiresAtMilliseconds = 120_000),
            response.copy(guideKeyFingerprint = ByteArray(32)), response.copy(offerCertificateFingerprint = ByteArray(32)),
            response.copy(certificateFingerprint = offer.certificateFingerprint)).forEach {
            assertThrows(IllegalArgumentException::class.java) { offer.validateResponse(it, 1_000) }
        }
    }
    @Test fun enrollmentExpiryAndNonCanonicalQRRejected() {
        listOf(-1L, 0L, 121_000L, Long.MAX_VALUE).forEach { now ->
            assertThrows(IllegalArgumentException::class.java) { offer.validate(now) }
        }
        listOf(offer.qrText() + "=", offer.qrText() + "\n", offer.qrText().replace("goh-hub:1:", "goh-hub:2:")).forEach {
            assertThrows(IllegalArgumentException::class.java) { GatewayPairingMessage.fromQR(it) }
        }
    }
    @Test fun everyLaneRoundTripsAndUnknownGenerationOrLaneRejected() {
        GatewayLane.entries.forEach { lane ->
            val value = GatewayLaneRequest(offer.pairingID, offer.roomID, if (lane == GatewayLane.HUB_CONTROL) 0 else 8, lane)
            assertEquals(45, value.encode().size)
            assertEquals(value, GatewayLaneRequest.decode(value.encode()))
        }
        assertThrows(IllegalArgumentException::class.java) { GatewayLaneRequest(offer.pairingID, offer.roomID, 0, GatewayLane.ADMISSION).encode() }
        val bytes = GatewayLaneRequest(offer.pairingID, offer.roomID, 1, GatewayLane.CONTROL).encode()
        bytes[44] = 99
        assertThrows(Exception::class.java) { GatewayLaneRequest.decode(bytes) }
    }
    @Test fun descriptorPreservesOriginalPlatformAndKeyAcrossCompanion() {
        val value = GatewayRoomDescriptor(9, 3, BluetoothRoomRecord(offer.roomID, offer.guideID, "Tour — جولة", false, true, 2), key)
        val decoded = GatewayRoomDescriptor.decode(value.encode())
        assertArrayEquals(value.encode(), decoded.encode()); decoded.validate(offer)
        assertEquals(false, decoded.record.isAndroid)
        assertThrows(IllegalArgumentException::class.java) { decoded.copy(guidePublicKey = byteArrayOf(4) + ByteArray(64)).validate(offer) }
    }
    @Test fun truncatedAndExtendedRecordsNeverDecode() {
        val data = offer.encode()
        data.indices.forEach { length -> assertThrows(Exception::class.java) { GatewayPairingMessage.decode(data.copyOf(length)) } }
        assertThrows(Exception::class.java) { GatewayPairingMessage.decode(data + byteArrayOf(0)) }
    }
    @Test fun fiftyMillisecondQueueDropsWholeAudioAndPreservesControl() {
        val queue = NearbyRealtimeQueue(50)
        queue.offer(byteArrayOf(1, 2), true, 0); queue.offer(byteArrayOf(3, 4), false, 0)
        assertArrayEquals(byteArrayOf(3, 4), queue.next(51)); assertEquals(1, queue.dropped)
    }
}
