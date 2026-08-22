package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.AssetRequestPayload
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import com.aessam.toursession.TargetSnapshotPayload
import com.aessam.toursession.TourVisualMode
import com.aessam.toursession.VisualFocusSnapshotPayload
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.net.InetAddress
import java.net.Socket
import javax.net.SocketFactory

class LocalSessionTransportTest {
    @Test
    fun goh2HelloRegistersGuestAndRealtimePayloadArrives() {
        val guide = UDPAudioPlane()
        val guest = UDPAudioPlane()
        val sessionID = UUID.randomUUID()
        val guestID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val joined = CountDownLatch(1)
        val audioReceived = CountDownLatch(1)
        val receivedPayload = AtomicReference<ByteArray>()

        try {
            guide.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guide",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guide.setSessionEventHandler { event ->
                if (event is AudioSessionEvent.Joined) {
                    assertEquals(guestID, event.participant.participantId)
                    joined.countDown()
                }
            }
            guide.startBroadcasting(sessionID.toString(), AudioQuality.STANDARD)

            guest.hostIP = "127.0.0.1"
            guest.configureSession(
                sessionID,
                guestID,
                "Guest",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guest.startListening(sessionID.toString()) { payload ->
                receivedPayload.set(payload)
                audioReceived.countDown()
            }

            assertTrue("Guest did not join", joined.await(3, TimeUnit.SECONDS))
            val expected = byteArrayOf(0x10, 0x20, 0x30, 0x40)
            guide.sendAudio(expected)
            assertTrue("Audio did not arrive", audioReceived.await(3, TimeUnit.SECONDS))
            assertArrayEquals(expected, receivedPayload.get())
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun independentControlLaneAuthenticatesBothDirections() {
        val guide = LocalSessionControlTransport()
        val guest = LocalSessionControlTransport()
        val sessionID = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val guestID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val targetID = UUID.randomUUID()
        val joined = CountDownLatch(1)
        val connected = CountDownLatch(1)
        val targetReceived = CountDownLatch(1)
        val focusReceived = CountDownLatch(1)
        val heartbeatReceived = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val failure = AtomicReference<String>()
        val socketFactory = CountingSocketFactory()

        try {
            guide.configureSession(sessionID, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            guide.setEventHandler { event ->
                when (event) {
                    is SessionControlEvent.GuestJoined -> {
                        assertEquals(guestID, event.participant.participantId)
                        joined.countDown()
                    }
                    is SessionControlEvent.EnvelopeReceived -> {
                        if (event.envelope.kind == SessionMessageKind.HEARTBEAT) {
                            assertEquals(guestID, event.envelope.senderId)
                            assertArrayEquals(byteArrayOf(0x47, 0x4f, 0x48, 0x32), event.envelope.payload)
                            heartbeatReceived.countDown()
                        }
                    }
                    is SessionControlEvent.GuestDisconnected -> {
                        assertEquals(guestID, event.participantID)
                        disconnected.countDown()
                    }
                    is SessionControlEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }
            guide.startGuide()

            guest.hostIP = "127.0.0.1"
            guest.setGuestSocketFactory(socketFactory)
            guest.configureSession(sessionID, guestID, "Guest", ParticipantPlatform.ANDROID, credential)
            guest.setEventHandler { event ->
                when (event) {
                    SessionControlEvent.Connected -> connected.countDown()
                    is SessionControlEvent.EnvelopeReceived -> {
                        when (event.envelope.kind) {
                            SessionMessageKind.TARGET_SNAPSHOT -> {
                                assertEquals(guideID, event.envelope.senderId)
                                val target = TargetSnapshotPayload.decode(event.envelope.payload)
                                assertEquals(targetID, target.targetID)
                                assertEquals("Main Gate", target.label)
                                targetReceived.countDown()
                            }
                            SessionMessageKind.VISUAL_FOCUS_SNAPSHOT -> {
                                assertEquals(guideID, event.envelope.senderId)
                                val focus = VisualFocusSnapshotPayload.decode(event.envelope.payload)
                                assertEquals(5L, focus.stateVersion)
                                assertEquals(TourVisualMode.MAP, focus.mode)
                                focusReceived.countDown()
                            }
                            else -> Unit
                        }
                    }
                    is SessionControlEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }
            guest.startGuest()

            assertTrue("Guest did not authenticate", joined.await(3, TimeUnit.SECONDS))
            assertTrue("Guest did not receive welcome", connected.await(3, TimeUnit.SECONDS))
            assertEquals(1, socketFactory.createdCount.get())
            val target = TargetSnapshotPayload(
                4,
                targetID,
                371_769_000,
                -35_889_000,
                "Main Gate",
                true,
            )
            guide.send(SessionMessageKind.TARGET_SNAPSHOT, target.encode())
            assertTrue("Target did not arrive", targetReceived.await(3, TimeUnit.SECONDS))

            val focus = VisualFocusSnapshotPayload(5, TourVisualMode.MAP)
            guide.send(SessionMessageKind.VISUAL_FOCUS_SNAPSHOT, focus.encode())
            assertTrue("Shared-screen mode did not arrive", focusReceived.await(3, TimeUnit.SECONDS))

            guest.send(SessionMessageKind.HEARTBEAT, byteArrayOf(0x47, 0x4f, 0x48, 0x32))
            assertTrue("Heartbeat did not arrive", heartbeatReceived.await(3, TimeUnit.SECONDS))

            guest.stop()
            assertTrue("Guest disconnect did not arrive", disconnected.await(3, TimeUnit.SECONDS))
            assertEquals(null, failure.get())
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun controlLaneRejectsGuestWithWrongTourCode() {
        val guide = LocalSessionControlTransport(50_031)
        val guest = LocalSessionControlTransport(50_031)
        val sessionID = UUID.randomUUID()
        val failure = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val message = AtomicReference<String>()
        try {
            guide.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guide",
                ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", sessionID),
            )
            guide.startGuide()
            guest.hostIP = "127.0.0.1"
            guest.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AC", sessionID),
            )
            guest.setEventHandler { event ->
                if (event is SessionControlEvent.Failed) {
                    message.set(event.message)
                    failure.countDown()
                } else if (event == SessionControlEvent.Disconnected) {
                    disconnected.countDown()
                }
            }
            guest.startGuest()
            assertTrue("Wrong code was not rejected", failure.await(3, TimeUnit.SECONDS))
            assertTrue(message.get().contains("guide connection failed"))
            assertFalse(
                "A failed authentication must not also emit a stale disconnect",
                disconnected.await(250, TimeUnit.MILLISECONDS),
            )
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun independentAssetLaneSupportsTargetedManifestsAndGuestRequests() {
        val guide = LocalSessionAssetTransport()
        val guest = LocalSessionAssetTransport()
        val sessionID = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val guestID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val packID = UUID.randomUUID()
        val hash = "ab".repeat(32)
        val joined = CountDownLatch(1)
        val connected = CountDownLatch(1)
        val manifestReceived = CountDownLatch(1)
        val requestReceived = CountDownLatch(1)
        val failure = AtomicReference<String>()

        try {
            guide.configureSession(sessionID, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            guide.setEventHandler { event ->
                when (event) {
                    is SessionAssetEvent.GuestJoined -> joined.countDown()
                    is SessionAssetEvent.EnvelopeReceived -> {
                        if (event.envelope.kind == SessionMessageKind.ASSET_REQUEST) {
                            assertEquals(guestID, event.envelope.senderId)
                            assertEquals(7, AssetRequestPayload.decode(event.envelope.payload).offset)
                            requestReceived.countDown()
                        }
                    }
                    is SessionAssetEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }
            guide.startGuide()

            guest.hostIP = "127.0.0.1"
            guest.configureSession(sessionID, guestID, "Guest", ParticipantPlatform.ANDROID, credential)
            guest.setEventHandler { event ->
                when (event) {
                    SessionAssetEvent.Connected -> connected.countDown()
                    is SessionAssetEvent.EnvelopeReceived -> {
                        if (event.envelope.kind == SessionMessageKind.TOUR_PACK_MANIFEST) {
                            assertEquals(guideID, event.envelope.senderId)
                            val manifest = TourPackManifestPayload.decode(event.envelope.payload)
                            assertEquals(packID, manifest.packID)
                            manifestReceived.countDown()
                        }
                    }
                    is SessionAssetEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }
            guest.startGuest()

            assertTrue("Guest did not authenticate", joined.await(3, TimeUnit.SECONDS))
            assertTrue("Guest did not receive welcome", connected.await(3, TimeUnit.SECONDS))
            val manifest = TourPackManifestPayload(
                packID,
                1,
                "Alhambra",
                listOf(
                    TourAssetDescriptor(
                        "gate-left",
                        TourAssetKind.SLIDE,
                        hash,
                        18,
                        0,
                        "image/jpeg",
                    ),
                ),
            )
            guide.send(SessionMessageKind.TOUR_PACK_MANIFEST, manifest.encode(), guestID)
            assertTrue("Manifest did not arrive", manifestReceived.await(3, TimeUnit.SECONDS))

            guest.send(SessionMessageKind.ASSET_REQUEST, AssetRequestPayload(hash, 7).encode(), null)
            assertTrue("Asset request did not arrive", requestReceived.await(3, TimeUnit.SECONDS))
            assertEquals(null, failure.get())
        } finally {
            guest.stop()
            guide.stop()
        }
    }
}

private fun testCredential(sessionID: UUID): SessionCredential =
    SessionCredential.derive("23456789AB", sessionID)

private class CountingSocketFactory : SocketFactory() {
    private val delegate = getDefault()
    val createdCount = AtomicInteger()

    override fun createSocket(): Socket {
        createdCount.incrementAndGet()
        return delegate.createSocket()
    }

    override fun createSocket(host: String, port: Int): Socket = delegate.createSocket(host, port)

    override fun createSocket(
        host: String,
        port: Int,
        localHost: InetAddress,
        localPort: Int,
    ): Socket = delegate.createSocket(host, port, localHost, localPort)

    override fun createSocket(host: InetAddress, port: Int): Socket = delegate.createSocket(host, port)

    override fun createSocket(
        address: InetAddress,
        port: Int,
        localAddress: InetAddress,
        localPort: Int,
    ): Socket = delegate.createSocket(address, port, localAddress, localPort)
}
