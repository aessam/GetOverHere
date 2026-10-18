package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors RelayProtocolTests.swift (ADR-081); the pinned fixture must stay identical on both platforms. */
class RelayProtocolTest {
    private val fixture = "assignment=00000000000000076f1c5c6a0000400080000000000000a1020000018bcfe5687b016f1c5c6a0000400080000000000000a2|upstream=016f1c5c6a0000400080000000000000b10200000005474f483201|decisions=forward,duplicate,conflict,expired,forward,forward,forward|snapshots=bearingSnapshot:4,presentationSnapshot:5"

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

    private class Guide {
        val session: UUID = UUID.randomUUID(); val id: UUID = UUID.randomUUID(); val stream: UUID = UUID.randomUUID()
        val signer = GuideFrameSigner(session, id)
        fun verifier() = GuideFrameVerifier(signer.publicKey, session, id)
        fun frame(kind: SessionMessageKind, sequence: Long, by: GuideFrameSigner = signer): ByteArray =
            by.sign(SealedSessionEnvelope(lane = kind.requiredLane, kind = kind, sequence = sequence, sessionId = session,
                senderId = id, streamId = stream, sealedPayload = ByteArray(16))).encode()
    }

    @Test fun forwarderWindowForgetsOldestIdentity() {
        val guide = Guide()
        val forwarder = RelayForwarder(guide.verifier())
        for (sequence in 1..RelayForwarder.WINDOW_SIZE + 1L) {
            assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(guide.frame(SessionMessageKind.HEARTBEAT, sequence), 0, 0))
        }
        assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(guide.frame(SessionMessageKind.HEARTBEAT, 1), 0, 0))
        assertEquals(RelayForwarder.Decision.CONFLICT,
            forwarder.admit(guide.frame(SessionMessageKind.HEARTBEAT, RelayForwarder.WINDOW_SIZE.toLong()), 0, 0))
        assertTrue(forwarder.snapshotFrames.isEmpty())
    }

    /** A frame not signed by the pinned guide changes nothing: no pre-emption, no cache poisoning. */
    @Test fun unverifiedFramesAreRejectedBeforeAnyState() {
        val guide = Guide()
        val member = GuideFrameSigner(guide.session, guide.id)
        val forwarder = RelayForwarder(guide.verifier())
        val forged = guide.frame(SessionMessageKind.PRESENTATION_SNAPSHOT, 9, by = member)
        assertThrows(Exception::class.java) { forwarder.admit(forged, 0, 0) }
        assertTrue(forwarder.snapshotFrames.isEmpty())
        val real = guide.frame(SessionMessageKind.PRESENTATION_SNAPSHOT, 9)
        assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(real, 0, 0))
        assertEquals(1, forwarder.snapshotFrames.size)
        val tampered = real.copyOf().also { it[it.size - 70] = (it[it.size - 70].toInt() xor 1).toByte() }
        assertThrows(Exception::class.java) { forwarder.admit(tampered, 0, 0) }
    }
}
