package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.RelayHub
import com.aessam.comeoverhere.core.RelayLaneServer
import com.aessam.comeoverhere.core.RelayRoute
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.toursession.AudioReadinessPayload
import com.aessam.toursession.AudioReadinessStatus
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.RelayHostAdvert
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The far guest's real control lane in relay mode against a real bridge (ADR-081 P3, ADR-083), over loopback. */
class RelayFarGuestTest {
    private val session = UUID.randomUUID()
    private val guideID = UUID.randomUUID()
    private val bridgeID = UUID.randomUUID()
    private val stream = UUID.randomUUID()
    private val credential = SessionCredential.derive("23456789AB", session)
    private val signer = GuideFrameSigner(session, guideID)
    private val guideSealer = SessionFrameSealer(credential)
    private var sequence = 0L
    private val hub = RelayHub(bridgeID, GuideFrameVerifier(signer.publicKey, session, guideID), credential,
        onRouteFault = { _, reason -> error("route fault: $reason") }, onIslandRevoked = {})
    private val server = RelayLaneServer(SessionLane.CONTROL, credential, session, guideID, bridgeID, hub)
    private val guest = LocalSessionControlTransport(port = server.port)
    private val events = LinkedBlockingQueue<SessionControlEvent>()

    @After fun tearDown() { guest.stop(); server.close() }

    private fun guideFrame(kind: SessionMessageKind, payload: ByteArray = ByteArray(8)): ByteArray {
        sequence += 1
        return signer.sign(guideSealer.seal(SessionEnvelope(lane = kind.requiredLane, kind = kind, sequence = sequence,
            sessionId = session, senderId = guideID, payload = payload), stream)).encode()
    }

    private fun assign(generation: Long) = hub.onUpstreamFrame(SessionLane.CONTROL, guideFrame(SessionMessageKind.BRIDGE_ASSIGNMENT,
        BridgeAssignmentPayload(generation, bridgeID, ParticipantPlatform.ANDROID, Long.MAX_VALUE, emptyList()).encode()), 0, 0)

    private fun startGuest(route: RelayRoute) {
        guest.configureGuideAuthentication(SessionGuideAuthentication.Guest(GuideFrameVerifier(signer.publicKey, session, guideID)))
        guest.configureSession(session, UUID.randomUUID(), "Far guest", ParticipantPlatform.ANDROID, credential)
        guest.hostIP = "127.0.0.1"
        guest.setRelayRoute(route)
        guest.setEventHandler { events += it }
        guest.startGuest()
    }

    private fun next(): SessionControlEvent = requireNotNull(events.poll(5, TimeUnit.SECONDS)) { "no session event" }

    private fun nextEnvelope(): SessionEnvelope {
        while (true) {
            val event = next()
            if (event is SessionControlEvent.EnvelopeReceived) return event.envelope
        }
    }

    @Test fun farGuestJoinsThroughBridgeAndReceivesGuideFrames() {
        assign(1)
        val presentation = guideFrame(SessionMessageKind.PRESENTATION_SNAPSHOT)
        hub.onUpstreamFrame(SessionLane.CONTROL, presentation, 0, 0)
        startGuest(RelayRoute(RelayHostAdvert(bridgeID, 1), guideID))
        assertEquals(SessionControlEvent.Connected, next())
        // The cached assignment and presentation replay first; both are guide frames, verified with the pinned key.
        val replayed = listOf(nextEnvelope(), nextEnvelope())
        assertEquals(setOf(SessionMessageKind.BRIDGE_ASSIGNMENT, SessionMessageKind.PRESENTATION_SNAPSHOT), replayed.map { it.kind }.toSet())
        assertTrue(replayed.all { it.senderId == guideID })

        // The guest's own advisory upstream frame must not end its lane.
        guest.send(SessionMessageKind.AUDIO_STATUS, AudioReadinessPayload(AudioReadinessStatus.PLAYING, 1u).encode())
        val deadline = System.currentTimeMillis() + 5_000
        while (server.upstreamFrames < 1 && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals(1L, server.upstreamFrames)
        hub.onUpstreamFrame(SessionLane.CONTROL, guideFrame(SessionMessageKind.TARGET_SNAPSHOT), 0, 0)
        val live = nextEnvelope()
        assertEquals(SessionMessageKind.TARGET_SNAPSHOT, live.kind)
        assertEquals(guideID, live.senderId)
    }

    @Test fun staleGenerationIsRejectedAndNeverConnects() {
        assign(2)
        startGuest(RelayRoute(RelayHostAdvert(bridgeID, 1), guideID)) // discovered before the guide renewed
        val event = next()
        assertTrue("expected a failure, got $event", event is SessionControlEvent.Failed)
        assertTrue(events.none { it == SessionControlEvent.Connected })
    }
}
