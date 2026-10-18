package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.RelayChildWriter
import com.aessam.comeoverhere.core.RelayHub
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** RelayHub (ADR-081 P1): verified fan-out, dedup, snapshots for late peers, assignment tracking. */
class RelayHubTest {
    private class Writer(private val capacity: Int = Int.MAX_VALUE) : RelayChildWriter {
        val frames = mutableListOf<ByteArray>()
        var closed = false
        override fun enqueue(frame: ByteArray): Boolean = (frames.size < capacity && !closed).also { if (it) frames += frame }
        override fun close() { closed = true }
    }

    private val session = UUID.randomUUID()
    private val guideID = UUID.randomUUID()
    private val stream = UUID.randomUUID()
    private val bridgeID = UUID.randomUUID()
    private val credential = SessionCredential.derive("23456789AB", session)
    private val signer = GuideFrameSigner(session, guideID)
    private val sealer = SessionFrameSealer(credential)
    private var sequence = 0L
    private val faults = mutableListOf<Pair<SessionLane, String>>()
    private val revoked = mutableListOf<BridgeAssignmentPayload>()
    private val hub = RelayHub(bridgeID, GuideFrameVerifier(signer.publicKey, session, guideID), credential,
        onRouteFault = { lane, reason -> faults += lane to reason }, onIslandRevoked = { revoked += it })

    private fun frame(kind: SessionMessageKind, payload: ByteArray = ByteArray(8), by: GuideFrameSigner = signer): ByteArray {
        sequence += 1
        val envelope = SessionEnvelope(lane = kind.requiredLane, kind = kind, sequence = sequence, sessionId = session,
            senderId = guideID, payload = payload)
        return by.sign(sealer.seal(envelope, stream)).encode()
    }

    private fun assignment(bridge: UUID, generation: Long) = frame(SessionMessageKind.BRIDGE_ASSIGNMENT,
        BridgeAssignmentPayload(generation, bridge, ParticipantPlatform.ANDROID, Long.MAX_VALUE, emptyList()).encode())

    @Test fun fansOutVerifiedFramesPerLaneAndDropsDuplicates() {
        val a = Writer(); val b = Writer(); val control = Writer()
        hub.attach(SessionLane.REALTIME, a); hub.attach(SessionLane.REALTIME, b); hub.attach(SessionLane.CONTROL, control)
        val audio = frame(SessionMessageKind.AUDIO_BATCH)
        hub.onUpstreamFrame(SessionLane.REALTIME, audio, 0, 0)
        hub.onUpstreamFrame(SessionLane.REALTIME, audio, 0, 0) // the same frame arriving over a second route
        assertEquals(1, a.frames.size); assertEquals(1, b.frames.size)
        assertArrayEquals(audio, a.frames.single())
        assertTrue("control peers do not get realtime frames", control.frames.isEmpty())
        assertEquals(1L, hub.counters.duplicates)
        assertTrue(faults.isEmpty())
    }

    @Test fun forgedOrLateFramesNeverReachPeers() {
        val peer = Writer()
        hub.attach(SessionLane.REALTIME, peer)
        val member = GuideFrameSigner(session, guideID)
        hub.onUpstreamFrame(SessionLane.REALTIME, frame(SessionMessageKind.AUDIO_BATCH, by = member), 0, 0)
        assertEquals(SessionLane.REALTIME, faults.single().first)
        hub.onUpstreamFrame(SessionLane.REALTIME, frame(SessionMessageKind.AUDIO_BATCH), 0, 51)
        assertEquals(1L, hub.counters.expired)
        assertTrue(peer.frames.isEmpty())
    }

    @Test fun lateControlPeerGetsCachedStateFirst() {
        val presentation = frame(SessionMessageKind.PRESENTATION_SNAPSHOT)
        hub.onUpstreamFrame(SessionLane.CONTROL, presentation, 0, 0)
        val late = Writer()
        hub.attach(SessionLane.CONTROL, late)
        assertArrayEquals(presentation, late.frames.single())
        val next = frame(SessionMessageKind.TARGET_SNAPSHOT)
        hub.onUpstreamFrame(SessionLane.CONTROL, next, 0, 0)
        assertArrayEquals(next, late.frames.last())
    }

    @Test fun assignmentNamingThisBridgeIsKeptAndAnotherRevokesTheIsland() {
        val peer = Writer()
        hub.attach(SessionLane.REALTIME, peer)
        val mine = assignment(bridgeID, 1)
        hub.onUpstreamFrame(SessionLane.CONTROL, mine, 0, 0)
        assertArrayEquals(mine, hub.assignmentFrame)
        assertEquals(bridgeID, hub.assignment!!.bridgeID)
        hub.onUpstreamFrame(SessionLane.CONTROL, assignment(UUID.randomUUID(), 2), 0, 0)
        assertNull(hub.assignmentFrame)
        assertEquals(2L, revoked.single().generation)
        assertTrue("island peers are closed when another bridge is assigned", peer.closed)
    }

    @Test fun overloadedPeerIsDroppedWithoutAffectingOthers() {
        val slow = Writer(capacity = 1); val healthy = Writer()
        hub.attach(SessionLane.REALTIME, slow); hub.attach(SessionLane.REALTIME, healthy)
        repeat(3) { hub.onUpstreamFrame(SessionLane.REALTIME, frame(SessionMessageKind.AUDIO_BATCH), 0, 0) }
        assertTrue(slow.closed)
        assertEquals(3, healthy.frames.size)
        assertEquals(1L, hub.counters.dropped)
    }
}
