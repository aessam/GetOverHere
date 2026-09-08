package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionAuthenticator
import com.aessam.toursession.SessionCapability
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Socket capacity only: 30 loopback clients are not 30 Aware data paths or radio qualification. */
class NativeParticipantCapacityTest {
    @Test(timeout = 30_000) fun controlCapRejectsBeforeWelcomeAndPermitsSameMemberReplacement() = checkCapacity(SessionLane.CONTROL)
    @Test(timeout = 30_000) fun assetCapRejectsBeforeWelcomeAndPermitsSameMemberReplacement() = checkCapacity(SessionLane.ASSET)
    @Test(timeout = 30_000) fun audioCapRejectsBeforeWelcomeAndPermitsSameMemberReplacement() = checkCapacity(SessionLane.REALTIME)

    private fun checkCapacity(lane: SessionLane) {
        val room = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val signer = GuideFrameSigner(room, guideID)
        val credential = SessionCredential.derive("23456789AB", room)
        val port = ServerSocket(0).use { it.localPort }
        val joined = LinkedBlockingQueue<UUID>()
        val disconnected = LinkedBlockingQueue<Boolean>()
        val authentication = SessionGuideAuthentication.Guide(signer)
        val stop: () -> Unit
        when (lane) {
            SessionLane.CONTROL -> {
                val guide = LocalSessionControlTransport(port)
                guide.configureGuideAuthentication(authentication)
                guide.configureSession(room, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
                guide.setEventHandler {
                    if (it is SessionControlEvent.GuestJoined) joined.offer(it.participant.participantId)
                    if (it is SessionControlEvent.GuestDisconnected) disconnected.offer(true)
                }
                guide.startGuide()
                stop = guide::clearSession
            }
            SessionLane.ASSET -> {
                val guide = LocalSessionAssetTransport(port)
                guide.configureGuideAuthentication(authentication)
                guide.configureSession(room, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
                guide.setEventHandler {
                    if (it is SessionAssetEvent.GuestJoined) joined.offer(it.participant.participantId)
                    if (it is SessionAssetEvent.GuestDisconnected) disconnected.offer(true)
                }
                guide.startGuide()
                stop = guide::clearSession
            }
            SessionLane.REALTIME -> {
                val guide = UDPAudioPlane(PassThroughRealtimeAudioCodecProvider(), port)
                guide.configureGuideAuthentication(authentication)
                guide.configureSession(room, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
                guide.setSessionEventHandler {
                    if (it is AudioSessionEvent.Joined) joined.offer(it.participant.participantId)
                    if (it is AudioSessionEvent.Disconnected) disconnected.offer(true)
                }
                guide.startBroadcasting(room.toString(), AudioQuality.STANDARD)
                stop = guide::clearSession
            }
        }
        val sockets = mutableListOf<Socket>()
        try {
            fun connect(member: UUID): Socket {
                val socket = Socket("127.0.0.1", port).apply { soTimeout = 3_000 }
                sockets += socket
                val input = DataInputStream(socket.getInputStream())
                val output = DataOutputStream(socket.getOutputStream())
                val verifier = GuideFrameVerifier(signer.publicKey, room, guideID)
                val opener = SessionFrameOpener(credential)
                fun readGuide(): SessionEnvelope {
                    val size = input.readInt()
                    require(size in 158..65_608)
                    return (opener.open(verifier.verify(ByteArray(size).also(input::readFully))) as SessionFrameOpenResult.Opened).envelope
                }
                val challengeEnvelope = readGuide()
                assertEquals(SessionMessageKind.AUTH_CHALLENGE, challengeEnvelope.kind)
                val challenge = AuthChallengePayload.decode(challengeEnvelope.payload)
                val nonce = SessionAuthenticator.randomNonce()
                val capabilities = SessionCapability.OPUS_DECODER.bit
                val proof = SessionAuthenticator.guestProof(credential, room, guideID, member, lane,
                    challenge.challengeNonce, nonce, SessionRole.GUEST, ParticipantPlatform.ANDROID, capabilities, "Guest")
                val hello = SessionEnvelope(lane = SessionLane.CONTROL, kind = SessionMessageKind.HELLO, sequence = 0,
                    sessionId = room, senderId = member, payload = HelloPayload(SessionRole.GUEST, ParticipantPlatform.ANDROID,
                        capabilities, "Guest", lane, nonce, proof).encode())
                val bytes = SessionFrameSealer(credential).seal(hello, UUID.randomUUID()).encode()
                output.writeInt(bytes.size); output.write(bytes); output.flush()
                assertEquals(SessionMessageKind.WELCOME, readGuide().kind)
                return socket
            }
            val members = List(30) { UUID.randomUUID() }
            members.forEach { member -> connect(member); assertEquals(member, joined.poll(3, TimeUnit.SECONDS)) }
            assertThrows("31st distinct member received welcome", EOFException::class.java) { connect(UUID.randomUUID()) }
            assertTrue(joined.isEmpty())
            assertTrue("Capacity rejection evicted an authenticated listener", disconnected.isEmpty())
            connect(members.first())
            assertEquals(members.first(), joined.poll(3, TimeUnit.SECONDS))
            assertEquals(true, disconnected.poll(3, TimeUnit.SECONDS))
            assertTrue("Replacement evicted a different listener", disconnected.isEmpty())
            assertEquals("Replacement closes only the member's old connection", -1, sockets.first().getInputStream().read())
            // Every other authenticated peer remains connected until the guide is explicitly stopped.
            stop()
            sockets.drop(1).forEach { socket -> assertEquals(-1, socket.getInputStream().read()) }
        } finally { sockets.forEach { it.close() }; stop() }
    }
}
