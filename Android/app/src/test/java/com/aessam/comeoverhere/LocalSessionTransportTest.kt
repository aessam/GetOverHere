package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.comeoverhere.core.NativeEncodedAudioPacket
import com.aessam.comeoverhere.core.RealtimeAudioCodecProvider
import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.RealtimeAudioEncoderInterface
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionCapability
import com.aessam.toursession.SessionEnvelope
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
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.io.DataOutputStream
import javax.net.SocketFactory

class LocalSessionTransportTest {
    @Test
    fun goh2HelloRegistersGuestAndRealtimePayloadArrives() {
        val provider = PassThroughRealtimeAudioCodecProvider()
        val guide = UDPAudioPlane(provider)
        val guest = UDPAudioPlane(provider)
        val factory = CountingSocketFactory()
        val sessionID = UUID.randomUUID()
        val guestID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val joined = CountDownLatch(1)
        val audioReceived = CountDownLatch(1)
        val receivedPayload = AtomicReference<ByteArray>()
        val audioThreadName = AtomicReference<String>()

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
            guest.setGuestSocketFactory(factory)
            guest.configureSession(
                sessionID,
                guestID,
                "Guest",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guest.startListening(sessionID.toString()) { payload ->
                receivedPayload.set(payload)
                // FND-5: PCM must be delivered from the clocked playout thread, never the read loop.
                audioThreadName.set(Thread.currentThread().name)
                audioReceived.countDown()
            }

            assertTrue("Guest did not join", joined.await(3, TimeUnit.SECONDS))
            // FND-4: Nagle is disabled on the connecting and the accepted realtime socket.
            assertTrue("guest socket keeps Nagle", factory.created.single().tcpNoDelay)
            assertTrue("accepted socket keeps Nagle", guide.acceptedClientSockets().single().tcpNoDelay)

            val expected = byteArrayOf(0x10, 0x20, 0x30, 0x40)
            guide.sendAudio(expected)
            guide.sendAudio(expected)
            guide.sendAudio(expected)
            assertTrue("Audio did not arrive", audioReceived.await(3, TimeUnit.SECONDS))
            assertArrayEquals(expected, receivedPayload.get())
            assertEquals("goh2-audio-playout", audioThreadName.get())
            // FND-3: encode+seal never runs on the caller (main) thread.
            assertEquals(setOf("audio-encode-seal"), provider.encodeThreadNames.toSet())
            assertFalse(provider.encodeThreadNames.contains(Thread.currentThread().name))
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun guestAudioLaneReportsGuideClose() {
        val provider = PassThroughRealtimeAudioCodecProvider()
        val guide = UDPAudioPlane(provider)
        val guest = UDPAudioPlane(provider)
        val sessionID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val joined = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val failureMessage = AtomicReference<String>()

        try {
            startAudioPair(guide, guest, sessionID, credential, credential, joined) { event ->
                if (event is AudioSessionEvent.Failed) {
                    failureMessage.set(event.message)
                    failed.countDown()
                }
            }
            assertTrue("Guest did not join", joined.await(3, TimeUnit.SECONDS))

            guide.stop()

            assertTrue("Guest audio lane did not report the guide close", failed.await(3, TimeUnit.SECONDS))
            assertTrue(failureMessage.get(), failureMessage.get().startsWith("Guide audio connection lost ("))
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun guestAudioLaneStaysSilentOnLocalStop() {
        val provider = PassThroughRealtimeAudioCodecProvider()
        val guide = UDPAudioPlane(provider)
        val guest = UDPAudioPlane(provider)
        val sessionID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val joined = CountDownLatch(1)
        val failed = CountDownLatch(1)

        try {
            startAudioPair(guide, guest, sessionID, credential, credential, joined) { event ->
                if (event is AudioSessionEvent.Failed) failed.countDown()
            }
            assertTrue("Guest did not join", joined.await(3, TimeUnit.SECONDS))

            guest.stop()

            assertFalse("Local stop must not report a lost guide", failed.await(500, TimeUnit.MILLISECONDS))
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun audioLaneWrongCodeStaysSilent() {
        val provider = PassThroughRealtimeAudioCodecProvider()
        val guide = UDPAudioPlane(provider)
        val guest = UDPAudioPlane(provider)
        val sessionID = UUID.randomUUID()
        val joined = CountDownLatch(1)
        val guestFailed = CountDownLatch(1)

        try {
            // RSK-3: the guest opens the guide's sealed challenge with its own credential first, so a
            // wrong code fails AEAD authentication (log only), never the handshake-EOF path.
            startAudioPair(
                guide,
                guest,
                sessionID,
                testCredential(sessionID),
                SessionCredential.derive("23456789AC", sessionID),
                joined,
            ) { event ->
                if (event is AudioSessionEvent.Failed) guestFailed.countDown()
            }

            assertFalse("Wrong code must not schedule a reconnect", guestFailed.await(500, TimeUnit.MILLISECONDS))
            assertEquals(1L, joined.count)
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    @Test
    fun audioLaneReportsLegacyProtocolVersionExplicitly() {
        val port = 50_033
        val server = ServerSocket(port)
        val serverThread = Thread {
            server.accept().use { socket ->
                DataOutputStream(socket.getOutputStream()).use { output ->
                    val legacyHeader = byteArrayOf(
                        0x47,
                        0x4f,
                        0x48,
                        0x32,
                        SessionEnvelope.MAJOR_VERSION.toByte(),
                    )
                    output.writeInt(legacyHeader.size)
                    output.write(legacyHeader)
                    output.flush()
                }
            }
        }.apply { start() }
        val guest = UDPAudioPlane(
            codecProvider = PassThroughRealtimeAudioCodecProvider(),
            audioPort = port,
        )
        val sessionID = UUID.randomUUID()
        val mismatch = CountDownLatch(1)
        val received = AtomicReference<AudioSessionEvent.VersionMismatch>()
        try {
            guest.hostIP = "127.0.0.1"
            guest.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                testCredential(sessionID),
            )
            guest.setSessionEventHandler { event ->
                if (event is AudioSessionEvent.VersionMismatch) {
                    received.set(event)
                    mismatch.countDown()
                }
            }
            guest.startListening(sessionID.toString()) {}

            assertTrue("Audio version mismatch was not reported", mismatch.await(3, TimeUnit.SECONDS))
            assertEquals(SessionEnvelope.MAJOR_VERSION, received.get().remoteMajor)
            assertEquals(SealedSessionEnvelope.MAJOR_VERSION, received.get().localMajor)
        } finally {
            guest.stop()
            server.close()
            serverThread.join(1_000)
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
    fun authenticatedGuideLeaveIsDeliveredBeforeTransportShutdown() {
        val port = 50_036
        val guide = LocalSessionControlTransport(port)
        val guest = LocalSessionControlTransport(port)
        val sessionID = UUID.randomUUID()
        val credential = testCredential(sessionID)
        val connected = CountDownLatch(1)
        val leaveReceived = CountDownLatch(1)
        val failure = AtomicReference<String>()
        try {
            guide.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guide",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guide.startGuide()
            guest.hostIP = "127.0.0.1"
            guest.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guest.setEventHandler { event ->
                when (event) {
                    SessionControlEvent.Connected -> connected.countDown()
                    is SessionControlEvent.EnvelopeReceived -> {
                        if (event.envelope.kind == SessionMessageKind.LEAVE) leaveReceived.countDown()
                    }
                    is SessionControlEvent.Failed -> failure.compareAndSet(null, event.message)
                    else -> Unit
                }
            }
            guest.startGuest()

            assertTrue("Guest did not authenticate", connected.await(3, TimeUnit.SECONDS))
            guide.send(SessionMessageKind.LEAVE, byteArrayOf())
            guide.stop()
            assertTrue("Terminal leave did not arrive", leaveReceived.await(3, TimeUnit.SECONDS))
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
        val rejected = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val message = AtomicReference<String>()
        val failure = AtomicReference<String>()
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
                when (event) {
                    is SessionControlEvent.CredentialRejected -> {
                        message.set(event.message)
                        rejected.countDown()
                    }
                    is SessionControlEvent.Failed -> failure.compareAndSet(null, event.message)
                    SessionControlEvent.Disconnected -> disconnected.countDown()
                    else -> Unit
                }
            }
            guest.startGuest()
            // FND-8: a wrong code is a distinct, terminal event, never the retried transport failure.
            assertTrue("Wrong code was not rejected", rejected.await(3, TimeUnit.SECONDS))
            assertTrue(message.get().contains("tour code was rejected"))
            assertEquals("A wrong code must not surface as a transport failure", null, failure.get())
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
    fun controlLaneReportsLegacyProtocolVersionExplicitly() {
        val port = 50_032
        val server = ServerSocket(port)
        val serverThread = Thread {
            server.accept().use { socket ->
                DataOutputStream(socket.getOutputStream()).use { output ->
                    val legacyHeader = byteArrayOf(
                        0x47,
                        0x4f,
                        0x48,
                        0x32,
                        SessionEnvelope.MAJOR_VERSION.toByte(),
                    )
                    output.writeInt(legacyHeader.size)
                    output.write(legacyHeader)
                    output.flush()
                }
            }
        }.apply { start() }
        val guest = LocalSessionControlTransport(port)
        val sessionID = UUID.randomUUID()
        val mismatch = CountDownLatch(1)
        val received = AtomicReference<SessionControlEvent.VersionMismatch>()
        try {
            guest.hostIP = "127.0.0.1"
            guest.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                testCredential(sessionID),
            )
            guest.setEventHandler { event ->
                if (event is SessionControlEvent.VersionMismatch) {
                    received.set(event)
                    mismatch.countDown()
                }
            }
            guest.startGuest()

            assertTrue("Version mismatch was not reported", mismatch.await(3, TimeUnit.SECONDS))
            assertEquals(SessionEnvelope.MAJOR_VERSION, received.get().remoteMajor)
            assertEquals(SealedSessionEnvelope.MAJOR_VERSION, received.get().localMajor)
        } finally {
            guest.stop()
            server.close()
            serverThread.join(1_000)
        }
    }

    @Test
    fun terminalClearErasesLocalSessionCredentials() {
        val sessionID = UUID.randomUUID()
        val transport = LocalSessionControlTransport(50_033)
        val failure = AtomicReference<String>()
        transport.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guide",
            ParticipantPlatform.ANDROID,
            testCredential(sessionID),
        )
        transport.setEventHandler { event ->
            if (event is SessionControlEvent.Failed) failure.set(event.message)
        }
        transport.clearSession()
        // FND-2: a lane that cannot start throws synchronously instead of emitting an asynchronous Failed.
        val error = assertThrows(IllegalStateException::class.java) { transport.startGuide() }

        assertTrue(error.message?.contains("not configured") == true)
        assertEquals(null, failure.get())
        assertFalse(transport.isActive)
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

private fun startAudioPair(
    guide: UDPAudioPlane,
    guest: UDPAudioPlane,
    sessionID: UUID,
    guideCredential: SessionCredential,
    guestCredential: SessionCredential,
    joined: CountDownLatch,
    guestHandler: (AudioSessionEvent) -> Unit,
) {
    guide.configureSession(sessionID, UUID.randomUUID(), "Guide", ParticipantPlatform.ANDROID, guideCredential)
    guide.setSessionEventHandler { event -> if (event is AudioSessionEvent.Joined) joined.countDown() }
    guide.startBroadcasting(sessionID.toString(), AudioQuality.STANDARD)

    guest.hostIP = "127.0.0.1"
    guest.configureSession(sessionID, UUID.randomUUID(), "Guest", ParticipantPlatform.ANDROID, guestCredential)
    guest.setSessionEventHandler(guestHandler)
    guest.startListening(sessionID.toString()) { }
}

private class CountingSocketFactory : SocketFactory() {
    private val delegate = getDefault()
    val createdCount = AtomicInteger()
    val created = CopyOnWriteArrayList<Socket>()

    override fun createSocket(): Socket {
        createdCount.incrementAndGet()
        return delegate.createSocket().also(created::add)
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

private class PassThroughRealtimeAudioCodecProvider : RealtimeAudioCodecProvider {
    val encodeThreadNames = CopyOnWriteArraySet<String>()

    override fun sessionCapabilities(): Long =
        SessionCapability.OPUS_ENCODER.bit or SessionCapability.OPUS_DECODER.bit

    override fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface =
        PassThroughRealtimeAudioEncoder(codec, encodeThreadNames)

    override fun makeDecoder(
        configuration: SessionAudioCodecConfiguration,
    ): RealtimeAudioDecoderInterface = PassThroughRealtimeAudioDecoder(configuration)
}

private class PassThroughRealtimeAudioEncoder(
    override val codec: SessionAudioCodec,
    private val encodeThreadNames: MutableSet<String>,
) : RealtimeAudioEncoderInterface {
    override val inputPCMByteCount: Int = 4
    private val configuration = SessionAudioCodecConfiguration(
        codec,
        16_000,
        1,
        20,
        20_000,
    )

    override fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket {
        encodeThreadNames += Thread.currentThread().name
        return NativeEncodedAudioPacket(configuration, pcm16LittleEndian.copyOf())
    }

    override fun close() = Unit
}

private class PassThroughRealtimeAudioDecoder(
    override val configuration: SessionAudioCodecConfiguration,
) : RealtimeAudioDecoderInterface {
    override fun decode(packet: ByteArray): ByteArray = packet.copyOf()
    override fun close() = Unit
}
