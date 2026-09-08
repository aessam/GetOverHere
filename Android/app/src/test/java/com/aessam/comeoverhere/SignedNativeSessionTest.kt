package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.RoomAdmissionTransport
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.comeoverhere.core.isNearbyAudioFrame
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataOutputStream
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Real local socket and admission/signature paths. Codec fixture is not an acoustic-quality claim. */
class SignedNativeSessionTest {
    @Test fun v2AdmissionBindsSameGuideAcrossAllThreeProductionLanes() {
        val room = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val guestID = UUID.randomUUID()
        val signer = GuideFrameSigner(room, guideID)
        val admissionPort = freePort()
        val controlPort = freePort()
        val assetPort = freePort()
        val audioPort = freePort()
        val admission = RoomAdmissionTransport(admissionPort)
        val guideControl = LocalSessionControlTransport(controlPort)
        val guestControl = LocalSessionControlTransport(controlPort)
        val guideAssets = LocalSessionAssetTransport(assetPort)
        val guestAssets = LocalSessionAssetTransport(assetPort)
        val provider = PassThroughRealtimeAudioCodecProvider()
        val guideAudio = UDPAudioPlane(provider, audioPort)
        val guestAudio = UDPAudioPlane(provider, audioPort)
        val connected = CountDownLatch(3)
        val delivered = CountDownLatch(3)
        val firstAudio = AtomicBoolean(true)
        val bytes = byteArrayOf(0x10, 0x20, 0x30, 0x40)
        try {
            admission.start(room, "23456789AB", signer)
            val admitted = admission.join("127.0.0.1", room, guideID, null)
            assertArrayEquals(signer.publicKey, admitted.guideIdentity.publicKey)
            val credential = SessionCredential.derive(admitted.mediaSecret, room)
            val outgoing = SessionGuideAuthentication.Guide(signer)
            val incoming = SessionGuideAuthentication.Guest(GuideFrameVerifier(admitted.guideIdentity.publicKey, room, guideID))
            listOf(guideControl to outgoing, guestControl to incoming).forEach { (lane, auth) ->
                lane.configureGuideAuthentication(auth)
                lane.configureSession(room, if (lane === guideControl) guideID else guestID, "Peer", ParticipantPlatform.ANDROID, credential)
            }
            listOf(guideAssets to outgoing, guestAssets to incoming).forEach { (lane, auth) ->
                lane.configureGuideAuthentication(auth)
                lane.configureSession(room, if (lane === guideAssets) guideID else guestID, "Peer", ParticipantPlatform.ANDROID, credential)
            }
            listOf(guideAudio to outgoing, guestAudio to incoming).forEach { (lane, auth) ->
                lane.configureGuideAuthentication(auth)
                lane.configureSession(room, if (lane === guideAudio) guideID else guestID, "Peer", ParticipantPlatform.ANDROID, credential)
            }
            guestControl.setEventHandler { event ->
                if (event is SessionControlEvent.Connected) connected.countDown()
                if (event is SessionControlEvent.EnvelopeReceived) {
                    assertArrayEquals(bytes, event.envelope.payload)
                    delivered.countDown()
                }
            }
            guestAssets.setEventHandler { event ->
                if (event is SessionAssetEvent.Connected) connected.countDown()
                if (event is SessionAssetEvent.EnvelopeReceived) {
                    assertArrayEquals(bytes, event.envelope.payload)
                    delivered.countDown()
                }
            }
            guideAudio.setSessionEventHandler { if (it is AudioSessionEvent.Joined) connected.countDown() }
            guideControl.startGuide(); guideAssets.startGuide()
            guideAudio.startBroadcasting(room.toString(), AudioQuality.STANDARD)
            guestControl.hostIP = "127.0.0.1"; guestAssets.hostIP = "127.0.0.1"; guestAudio.hostIP = "127.0.0.1"
            guestControl.startGuest(); guestAssets.startGuest()
            guestAudio.startListening(room.toString()) {
                assertArrayEquals(bytes, it)
                if (firstAudio.compareAndSet(true, false)) delivered.countDown()
            }
            assertTrue("Signed handshakes failed", connected.await(5, TimeUnit.SECONDS))
            guideControl.send(SessionMessageKind.TARGET_SNAPSHOT, bytes)
            guideAssets.send(SessionMessageKind.ASSET_CHUNK, bytes, guestID)
            repeat(3) { guideAudio.sendAudio(bytes) }
            assertTrue("Signed production payloads not delivered", delivered.await(5, TimeUnit.SECONDS))
        } finally {
            guestAudio.clearSession(); guideAudio.clearSession()
            guestControl.clearSession(); guideControl.clearSession()
            guestAssets.clearSession(); guideAssets.clearSession()
            admission.stop()
        }
    }

    @Test fun nativeLaneCannotStartWithoutExplicitAuthenticationAndClearErasesAuthority() {
        val room = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val lane = LocalSessionControlTransport(freePort())
        val credential = SessionCredential.derive("23456789AB", room)
        try {
            lane.configureSession(room, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            assertThrows(IllegalStateException::class.java) { lane.startGuide() }
            lane.configureGuideAuthentication(SessionGuideAuthentication.Guide(GuideFrameSigner(room, guideID)))
            lane.configureSession(room, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            lane.startGuide()
            lane.stop()
            lane.startGuide() // reconnect retains the same signer.
            lane.clearSession()
            lane.configureSession(room, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            assertThrows(IllegalStateException::class.java) { lane.startGuide() }
        } finally { lane.clearSession() }
    }

    @Test fun admittedGuestWithMediaKeyCannotImpersonateGuideOnNativeSocket() {
        val room = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val signer = GuideFrameSigner(room, guideID)
        val credential = SessionCredential.derive("23456789AB", room)
        ServerSocket(0).use { rogue ->
            val guest = LocalSessionControlTransport(rogue.localPort)
            val rejected = CountDownLatch(1)
            val connected = CountDownLatch(1)
            val server = Thread {
                rogue.accept().use { socket ->
                    val logical = SessionEnvelope(lane = SessionLane.CONTROL, kind = SessionMessageKind.AUTH_CHALLENGE,
                        sequence = 0, sessionId = room, senderId = guideID, payload = byteArrayOf())
                    val unsigned = SessionFrameSealer(credential).seal(logical, UUID.randomUUID()).encode()
                    DataOutputStream(socket.getOutputStream()).apply { writeInt(unsigned.size); write(unsigned); flush() }
                }
            }.apply { isDaemon = true; start() }
            try {
                guest.configureGuideAuthentication(SessionGuideAuthentication.Guest(GuideFrameVerifier(signer.publicKey, room, guideID)))
                guest.configureSession(room, UUID.randomUUID(), "Guest", ParticipantPlatform.ANDROID, credential)
                guest.hostIP = "127.0.0.1"
                guest.setEventHandler {
                    if (it is SessionControlEvent.AuthenticationFailed) rejected.countDown()
                    if (it is SessionControlEvent.Connected) connected.countDown()
                }
                guest.startGuest()
                assertTrue("Unsigned encrypted forgery not rejected", rejected.await(3, TimeUnit.SECONDS))
                assertEquals(1L, connected.count)
            } finally { guest.clearSession(); server.join(1_000) }
        }
    }

    @Test fun bridgeClassifiesSignedAudioWithoutTreatingClassificationAsAuthentication() {
        val room = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val signer = GuideFrameSigner(room, guideID)
        val verifier = SessionGuideAuthentication.Guest(GuideFrameVerifier(signer.publicKey, room, guideID))
        val logical = SessionEnvelope(lane = SessionLane.REALTIME, kind = SessionMessageKind.AUDIO_FRAME,
            sequence = 1, sessionId = room, senderId = guideID, payload = ByteArray(4))
        val sealed = SessionFrameSealer(SessionCredential.derive("23456789AB", room)).seal(logical, UUID.randomUUID())
        val signed = signer.sign(sealed).encode()
        assertTrue(isNearbyAudioFrame(signed))
        assertTrue(isNearbyAudioFrame(sealed.encode()))
        assertArrayEquals(sealed.encode(), verifier.decodeGuide(signed).encode())
        val forged = signed.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        assertTrue(isNearbyAudioFrame(forged)) // Scheduler must not claim authentication.
        assertThrows(IllegalArgumentException::class.java) { verifier.decodeGuide(forged) }
        assertThrows(IllegalArgumentException::class.java) { verifier.decodeGuide(sealed.encode()) }
        val malformed = signed.copyOf().also { it[7] = 0 }
        assertThrows(IllegalArgumentException::class.java) { isNearbyAudioFrame(malformed) }
    }

    private fun freePort(): Int = ServerSocket(0).use { it.localPort }
}
