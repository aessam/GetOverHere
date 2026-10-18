package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.GuideLaneConnector
import com.aessam.comeoverhere.core.IslandAdvertiserInterface
import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.RelayIslandHost
import com.aessam.comeoverhere.core.RelayLaneServer
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GatewayLane
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.RelayHostAdvert
import com.aessam.toursession.RelayLaneAuthenticator
import com.aessam.toursession.RelayLaneContext
import com.aessam.toursession.RelayWelcomePayload
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SessionAuthenticator
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** RelayIslandHost (ADR-081 P1 step 3): upstream tap → island lanes, with a fake advertiser instead of Aware. */
class RelayIslandHostTest {
    private class FakeAdvertiser : IslandAdvertiserInterface {
        val events = LinkedBlockingQueue<Pair<String, BluetoothRoomRecord?>>()
        @Volatile var connector: GuideLaneConnector? = null
        override fun start(record: BluetoothRoomRecord, connector: GuideLaneConnector) { this.connector = connector; events += "start" to record }
        override fun stop() { connector = null; events += "stop" to null }
    }

    private val session = UUID.randomUUID()
    private val guideID = UUID.randomUUID()
    private val bridgeID = UUID.randomUUID()
    private val stream = UUID.randomUUID()
    private val credential = SessionCredential.derive("23456789AB", session)
    private val signer = GuideFrameSigner(session, guideID)
    private val guideSealer = SessionFrameSealer(credential)
    private var sequence = 0L
    private val advertiser = FakeAdvertiser()
    private val admission = ServerSocket(0, 4, InetAddress.getLoopbackAddress())
    private val record = BluetoothRoomRecord(session, guideID, "Bridge tour", isAndroid = false, isLocked = false, admissionVersion = 2)
    private val host = RelayIslandHost(bridgeID, session, guideID, credential, GuideFrameVerifier(signer.publicKey, session, guideID),
        record, advertiser, assetFile = { null }, admissionPort = admission.localPort)

    @After fun tearDown() { host.close(); admission.close() }

    private fun guideFrame(kind: SessionMessageKind, payload: ByteArray = ByteArray(8)): ByteArray {
        sequence += 1
        return signer.sign(guideSealer.seal(SessionEnvelope(lane = kind.requiredLane, kind = kind, sequence = sequence,
            sessionId = session, senderId = guideID, payload = payload), stream)).encode()
    }

    private fun assignment(bridge: UUID, generation: Long) = guideFrame(SessionMessageKind.BRIDGE_ASSIGNMENT,
        BridgeAssignmentPayload(generation, bridge, ParticipantPlatform.ANDROID, Long.MAX_VALUE, emptyList()).encode())

    private fun nextEvent() = requireNotNull(advertiser.events.poll(5, TimeUnit.SECONDS)) { "advertiser event timed out" }

    /** A far guest's ADR-083 handshake over the connection the island advertiser handed out. */
    private fun join(connection: NearbyByteConnection, lane: SessionLane, generation: Long): BridgeAssignmentPayload {
        val participant = UUID.randomUUID()
        val opener = SessionFrameOpener(credential)
        fun open(frame: ByteArray) = (opener.open(SealedSessionEnvelope.decode(frame)) as SessionFrameOpenResult.Opened).envelope
        val challenge = AuthChallengePayload.decode(open(RelayLaneServer.readFrame(connection.input, 65_536)).payload)
        val context = RelayLaneContext(session, guideID, RelayHostAdvert(bridgeID, generation), participant, lane)
        val clientNonce = SessionAuthenticator.randomNonce()
        val proof = RelayLaneAuthenticator.guestProof(credential, context, challenge.challengeNonce, clientNonce, SessionRole.GUEST,
            ParticipantPlatform.ANDROID, 0, "Far guest")
        val hello = HelloPayload(SessionRole.GUEST, ParticipantPlatform.ANDROID, 0, "Far guest", lane, clientNonce, proof)
        RelayLaneServer.writeFrame(connection.output, SessionFrameSealer(credential).seal(SessionEnvelope(lane = SessionLane.CONTROL,
            kind = SessionMessageKind.HELLO, sequence = 0, sessionId = session, senderId = participant, payload = hello.encode()), UUID.randomUUID()).encode())
        return RelayWelcomePayload.decode(open(RelayLaneServer.readFrame(connection.input, 1_048_576)).payload).verify(credential, context,
            challenge.challengeNonce, clientNonce, GuideFrameVerifier(signer.publicKey, session, guideID), System.currentTimeMillis())
    }

    @Test fun islandStaysDownUntilTheGuideAssignsThisGuest() {
        host.onUpstreamFrame(SessionLane.CONTROL, guideFrame(SessionMessageKind.PRESENTATION_SNAPSHOT))
        host.onUpstreamFrame(SessionLane.CONTROL, assignment(UUID.randomUUID(), 1))
        Thread.sleep(200)
        assertTrue("no island for a guest that is not the bridge", advertiser.events.isEmpty())
        assertTrue(host.lanePorts().isEmpty())
    }

    @Test fun assignedGuestPublishesIslandAndRelaysGuideFrames() {
        val presentation = guideFrame(SessionMessageKind.PRESENTATION_SNAPSHOT)
        host.onUpstreamFrame(SessionLane.CONTROL, presentation)
        host.onUpstreamFrame(SessionLane.CONTROL, assignment(bridgeID, 1))
        val (event, published) = nextEvent()
        assertEquals("start", event)
        assertEquals(RelayHostAdvert(bridgeID, 1), published!!.relayHost)
        assertEquals(record.roomID, published.roomID)
        val connector = requireNotNull(advertiser.connector)

        val control = connector.connect(GatewayLane.CONTROL)
        assertEquals(bridgeID, join(control, SessionLane.CONTROL, 1).bridgeID)
        // Cached control state arrives first, without another upstream frame.
        assertArrayEquals(presentation, RelayLaneServer.readFrame(control.input, 1_048_576))

        val realtime = connector.connect(GatewayLane.REALTIME)
        join(realtime, SessionLane.REALTIME, 1)
        Thread.sleep(200) // the server attaches the peer after the welcome
        val audio = guideFrame(SessionMessageKind.AUDIO_BATCH)
        host.onUpstreamFrame(SessionLane.REALTIME, audio)
        assertArrayEquals(audio, RelayLaneServer.readFrame(realtime.input, 1_048_576))

        // Admission goes to the guest's own nearby bridge, which tunnels to the guide.
        connector.connect(GatewayLane.ADMISSION).close()
        admission.soTimeout = 5_000
        admission.accept().close()
        control.close(); realtime.close()
    }

    @Test fun anotherAssignmentClosesTheIsland() {
        host.onUpstreamFrame(SessionLane.CONTROL, assignment(bridgeID, 1))
        assertEquals("start", nextEvent().first)
        val port = host.lanePorts().getValue(SessionLane.REALTIME)
        host.onUpstreamFrame(SessionLane.CONTROL, assignment(UUID.randomUUID(), 2))
        assertEquals("stop", nextEvent().first)
        assertTrue(host.lanePorts().isEmpty())
        val refused = runCatching { java.net.Socket(InetAddress.getLoopbackAddress(), port).use { it.getInputStream().read() } }
        assertTrue("old island listener is closed", refused.isFailure || refused.getOrNull() == -1)
    }

    @Test fun renewedAssignmentRepublishesTheNewGeneration() {
        host.onUpstreamFrame(SessionLane.CONTROL, assignment(bridgeID, 1))
        assertEquals(1L, nextEvent().second!!.relayHost!!.bridgeGeneration)
        val ports = host.lanePorts()
        host.onUpstreamFrame(SessionLane.CONTROL, assignment(bridgeID, 2))
        assertEquals(2L, nextEvent().second!!.relayHost!!.bridgeGeneration)
        assertEquals("listeners survive a renewal", ports, host.lanePorts())
    }
}
