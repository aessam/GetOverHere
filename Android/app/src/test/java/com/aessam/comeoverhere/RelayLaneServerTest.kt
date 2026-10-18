package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.RelayHub
import com.aessam.comeoverhere.core.RelayLaneServer
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.AssetRequestPayload
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.PeerAssetAcceptance
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
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import com.aessam.toursession.lowercaseHex
import java.io.EOFException
import java.io.File
import java.net.InetAddress
import java.net.Socket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** RelayLaneServer over loopback (ADR-081 P1, ADR-083): a simulated guide and a hand-written far guest. */
class RelayLaneServerTest {
    private val session = UUID.randomUUID()
    private val guideID = UUID.randomUUID()
    private val bridgeID = UUID.randomUUID()
    private val stream = UUID.randomUUID()
    private val credential = SessionCredential.derive("23456789AB", session)
    private val signer = GuideFrameSigner(session, guideID)
    private val guideSealer = SessionFrameSealer(credential)
    private var sequence = 0L
    private val faults = mutableListOf<String>()
    private val hub = RelayHub(bridgeID, GuideFrameVerifier(signer.publicKey, session, guideID), credential,
        onRouteFault = { _, reason -> faults += reason }, onIslandRevoked = {})
    private val servers = mutableListOf<RelayLaneServer>()
    private val root: File = Files.createTempDirectory("GetOverHereRelay").toFile()

    @After fun tearDown() {
        servers.forEach(RelayLaneServer::close)
        check(root.deleteRecursively()) { "Temporary relay files not removed: $root" }
    }

    private fun guideFrame(kind: SessionMessageKind, payload: ByteArray = ByteArray(8)): ByteArray {
        sequence += 1
        return signer.sign(guideSealer.seal(SessionEnvelope(lane = kind.requiredLane, kind = kind, sequence = sequence,
            sessionId = session, senderId = guideID, payload = payload), stream)).encode()
    }

    private fun assign(generation: Long = 1) = hub.onUpstreamFrame(SessionLane.CONTROL, guideFrame(SessionMessageKind.BRIDGE_ASSIGNMENT,
        BridgeAssignmentPayload(generation, bridgeID, ParticipantPlatform.ANDROID, Long.MAX_VALUE, emptyList()).encode()), 0, 0)

    private fun server(lane: SessionLane, assets: (String) -> File? = { null }) =
        RelayLaneServer(lane, credential, session, guideID, bridgeID, hub, assets).also { servers += it }

    /** The far guest's side of ADR-083; returns the verified assignment and the open socket. */
    private fun join(server: RelayLaneServer, lane: SessionLane, with: SessionCredential = credential,
                     participant: UUID = UUID.randomUUID()): Pair<BridgeAssignmentPayload, Socket> {
        val socket = Socket(InetAddress.getLoopbackAddress(), server.port).apply { soTimeout = 5_000 }
        val input = socket.getInputStream(); val output = socket.getOutputStream()
        val opener = SessionFrameOpener(with)
        fun open(frame: ByteArray) = (opener.open(SealedSessionEnvelope.decode(frame)) as SessionFrameOpenResult.Opened).envelope
        val challengeEnvelope = open(RelayLaneServer.readFrame(input, 65_536))
        assertEquals(bridgeID, challengeEnvelope.senderId)
        val challenge = AuthChallengePayload.decode(challengeEnvelope.payload)
        val context = RelayLaneContext(session, guideID, RelayHostAdvert(bridgeID, 1), participant, lane)
        val clientNonce = SessionAuthenticator.randomNonce()
        val proof = RelayLaneAuthenticator.guestProof(with, context, challenge.challengeNonce, clientNonce, SessionRole.GUEST,
            ParticipantPlatform.ANDROID, 0, "Far guest")
        val hello = HelloPayload(SessionRole.GUEST, ParticipantPlatform.ANDROID, 0, "Far guest", lane, clientNonce, proof)
        RelayLaneServer.writeFrame(output, SessionFrameSealer(with).seal(SessionEnvelope(lane = SessionLane.CONTROL,
            kind = SessionMessageKind.HELLO, sequence = 0, sessionId = session, senderId = participant, payload = hello.encode()), UUID.randomUUID()).encode())
        val welcomeEnvelope = open(RelayLaneServer.readFrame(input, 1_048_576))
        assertEquals(SessionMessageKind.WELCOME, welcomeEnvelope.kind)
        val assignment = RelayWelcomePayload.decode(welcomeEnvelope.payload).verify(with, context, challenge.challengeNonce, clientNonce,
            GuideFrameVerifier(signer.publicKey, session, guideID), System.currentTimeMillis())
        return assignment to socket
    }

    @Test fun unassignedBridgeRefusesPeers() {
        val server = server(SessionLane.REALTIME)
        val socket = Socket(InetAddress.getLoopbackAddress(), server.port).apply { soTimeout = 5_000 }
        assertThrows(EOFException::class.java) { RelayLaneServer.readFrame(socket.getInputStream(), 65_536) }
        socket.close()
    }

    @Test fun assignedBridgeAdmitsMemberAndForwardsVerifiedGuideFrames() {
        assign()
        val server = server(SessionLane.REALTIME)
        val (assignment, socket) = join(server, SessionLane.REALTIME)
        assertEquals(bridgeID, assignment.bridgeID)
        Thread.sleep(200) // the server attaches the peer after sending the welcome
        val audio = guideFrame(SessionMessageKind.AUDIO_BATCH)
        hub.onUpstreamFrame(SessionLane.REALTIME, audio, 0, 0)
        val received = RelayLaneServer.readFrame(socket.getInputStream(), 1_048_576)
        assertArrayEquals(audio, received)
        assertEquals(SessionMessageKind.AUDIO_BATCH, GuideFrameVerifier(signer.publicKey, session, guideID).verify(received).kind)
        assertTrue(faults.isEmpty())
        socket.close()
    }

    @Test fun nonMemberGetsNoWelcome() {
        assign()
        val server = server(SessionLane.CONTROL)
        val outsider = SessionCredential.derive("ZZZZ9999AB", session)
        assertThrows(Exception::class.java) { join(server, SessionLane.CONTROL, with = outsider) }
    }

    @Test fun assetLaneServesHeldFilesOutsideTheHub() {
        assign()
        val bytes = ByteArray(70_000) { (it % 251).toByte() }
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes).lowercaseHex()
        val file = File(root, hash).apply { writeBytes(bytes) }
        val manifest = TourPackManifestPayload(UUID.randomUUID(), 1, "Tour",
            listOf(TourAssetDescriptor("slide", TourAssetKind.SLIDE, hash, bytes.size.toLong(), 0, "image/jpeg")))
        val forwardedBefore = hub.counters.forwarded
        val server = server(SessionLane.ASSET) { if (it == hash) file else null }
        val me = UUID.randomUUID()
        val (_, socket) = join(server, SessionLane.ASSET, participant = me)
        val sealer = SessionFrameSealer(credential); val opener = SessionFrameOpener(credential)
        val received = java.io.ByteArrayOutputStream()
        var offset = 0L; var request = 0L
        while (offset < bytes.size) {
            request += 1
            RelayLaneServer.writeFrame(socket.getOutputStream(), sealer.seal(SessionEnvelope(lane = SessionLane.ASSET,
                kind = SessionMessageKind.ASSET_REQUEST, sequence = request, sessionId = session, senderId = me,
                payload = AssetRequestPayload(hash, offset).encode()), UUID.randomUUID()).encode())
            val envelope = (opener.open(SealedSessionEnvelope.decode(RelayLaneServer.readFrame(socket.getInputStream(), 1_048_576)))
                as SessionFrameOpenResult.Opened).envelope
            assertEquals(bridgeID, envelope.senderId)
            val chunk = AssetChunkPayload.decode(envelope.payload)
            assertTrue("W6: accepted only for manifest files within length", PeerAssetAcceptance.accepts(chunk, manifest))
            received.write(chunk.bytes); offset += chunk.bytes.size
        }
        assertArrayEquals(bytes, received.toByteArray())
        assertEquals("bridge-sealed chunks never enter the hub", forwardedBefore, hub.counters.forwarded)
        socket.close()
    }
}
