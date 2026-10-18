package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors RelayProtocolTests.swift (ADR-081); the pinned fixture must stay identical on both platforms. */
class RelayProtocolTest {
    private val fixture = "assignment=00000000000000076f1c5c6a0000400080000000000000a1020000018bcfe5687b016f1c5c6a0000400080000000000000a2|upstream=016f1c5c6a0000400080000000000000b10200000005474f483201|decisions=forward,duplicate,conflict,expired,forward,forward,forward|snapshots=ec768fa4619a86bd,37e0ac21a9a914ba"

    @Test fun pinnedFixture() = assertEquals(fixture, TourSessionFixtures.relayFixture())

    @Test fun bridgeAssignmentRoundtripAndRejections() {
        val value = BridgeAssignmentPayload(-1L, UUID.randomUUID(), ParticipantPlatform.IOS, 1, listOf(UUID.randomUUID(), UUID.randomUUID()))
        assertEquals(value, BridgeAssignmentPayload.decode(value.encode()))
        assertThrows(RelayProtocolException::class.java) {
            BridgeAssignmentPayload(1, UUID.randomUUID(), ParticipantPlatform.IOS, 1, List(3) { UUID.randomUUID() })
        }
        val bytes = value.encode().also { it[24] = 3 }
        assertThrows(RelayProtocolException::class.java) { BridgeAssignmentPayload.decode(bytes) }
        assertThrows(RelayProtocolException::class.java) { BridgeAssignmentPayload.decode(value.encode() + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { BridgeAssignmentPayload.decode(value.encode().copyOf(value.encode().size - 1)) }
        assertEquals(SessionLane.CONTROL, SessionMessageKind.BRIDGE_ASSIGNMENT.requiredLane)
        assertEquals(1L shl 5, SessionCapability.RELAY_HOST.bit)
    }

    @Test fun upstreamRecordRoundtripAndRejections() {
        val value = RelayUpstreamRecord(UUID.randomUUID(), SessionLane.ASSET, ByteArray(300) { 7 })
        assertEquals(value, RelayUpstreamRecord.decode(value.encode()))
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord.decode(value.encode().also { it[0] = 2 }) }
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord.decode(value.encode().also { it[17] = 9 }) }
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord(UUID.randomUUID(), SessionLane.CONTROL, ByteArray(65_537)) }
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord.decode(value.encode() + byteArrayOf(0)) }
    }

    @Test fun forwarderWindowForgetsOldestIdentity() {
        val session = UUID.randomUUID(); val sender = UUID.randomUUID(); val stream = UUID.randomUUID()
        fun frame(sequence: Long): Pair<SealedSessionEnvelope, ByteArray> {
            val envelope = SealedSessionEnvelope(lane = SessionLane.CONTROL, kind = SessionMessageKind.HEARTBEAT, sequence = sequence,
                sessionId = session, senderId = sender, streamId = stream, sealedPayload = ByteArray(16))
            return envelope to envelope.encode()
        }
        val forwarder = RelayForwarder()
        for (sequence in 1..RelayForwarder.WINDOW_SIZE + 1L) {
            val (envelope, bytes) = frame(sequence)
            assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(envelope, bytes, 0, 0))
        }
        val (oldest, bytes) = frame(1)
        assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(oldest, bytes, 0, 0))
        val (recent, recentBytes) = frame(RelayForwarder.WINDOW_SIZE.toLong())
        assertEquals(RelayForwarder.Decision.DUPLICATE, forwarder.admit(recent, recentBytes, 0, 0))
        assertTrue(forwarder.snapshotFrames.isEmpty())
    }
}
