package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.NativeEncodedAudioPacket
import com.aessam.comeoverhere.core.RealtimeAudioCodecProvider
import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.RealtimeAudioEncoderInterface
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionCapability
import com.aessam.toursession.SessionCredential
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket
import java.util.UUID

/**
 * RSK-1 (ADR-047): every lane admits at most `MAXIMUM_PENDING_HANDSHAKES` accepted-but-unauthenticated
 * sockets. The next one is closed before a single handshake byte is written, and a slot is released the
 * moment the pending handshake returns or throws, so closing one pending peer admits the next. The bound
 * is above the 24-guest tour group so a simultaneous (re)join never rejects a legitimate guest.
 */
class HandshakeBoundTest {
    @Test
    fun controlLaneClosesPendingHandshakeBeyondBoundImmediately() {
        val port = 50_043
        val guide = LocalSessionControlTransport(port)
        val sessionID = UUID.randomUUID()
        try {
            guide.configureGuideAuthentication(com.aessam.comeoverhere.core.SessionGuideAuthentication.LegacyFixture)
            guide.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guide",
                ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", sessionID),
            )
            guide.startGuide()
            assertPendingHandshakeBeyondBoundIsClosed(port)
        } finally {
            guide.stop()
        }
    }

    @Test
    fun audioLaneClosesPendingHandshakeBeyondBoundImmediately() {
        val port = 50_044
        val guide = UDPAudioPlane(BoundTestCodecProvider(), port)
        val sessionID = UUID.randomUUID()
        try {
            guide.configureGuideAuthentication(com.aessam.comeoverhere.core.SessionGuideAuthentication.LegacyFixture)
            guide.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guide",
                ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", sessionID),
            )
            guide.startBroadcasting(sessionID.toString(), AudioQuality.STANDARD)
            assertPendingHandshakeBeyondBoundIsClosed(port)
        } finally {
            guide.stop()
        }
    }

    private fun assertPendingHandshakeBeyondBoundIsClosed(port: Int) {
        val silent = mutableListOf<Socket>()
        try {
            repeat(PENDING_HANDSHAKE_BOUND) { silent += Socket("127.0.0.1", port).apply { soTimeout = 1_000 } }
            // Let the accept loop admit every pending peer before the one beyond the bound arrives.
            Thread.sleep(200)

            Socket("127.0.0.1", port).use { beyond ->
                beyond.soTimeout = 1_000
                assertEquals(
                    "pending handshake beyond the bound must be closed without a challenge",
                    -1,
                    beyond.getInputStream().read(),
                )
            }
            assertTrue(
                "first pending handshake must receive the sealed challenge",
                silent[0].getInputStream().read() >= 0,
            )

            // Closing one pending peer makes its handshake throw and releases the slot (accept-vs-release race: 200 ms).
            silent.removeAt(0).close()
            Thread.sleep(200)
            Socket("127.0.0.1", port).use { admitted ->
                admitted.soTimeout = 2_000
                assertTrue(
                    "released slot must admit the next connection",
                    admitted.getInputStream().read() >= 0,
                )
            }
        } finally {
            silent.forEach { it.close() }
        }
    }

    private companion object {
        /** Mirrors `MAXIMUM_PENDING_HANDSHAKES` in LocalSessionControlTransport.kt and UDPAudioPlane.kt. */
        const val PENDING_HANDSHAKE_BOUND = 32
    }
}

private class BoundTestCodecProvider : RealtimeAudioCodecProvider {
    override fun sessionCapabilities(): Long =
        SessionCapability.OPUS_ENCODER.bit or SessionCapability.OPUS_DECODER.bit

    override fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface = BoundTestEncoder(codec)

    override fun makeDecoder(configuration: SessionAudioCodecConfiguration): RealtimeAudioDecoderInterface =
        BoundTestDecoder(configuration)
}

private class BoundTestEncoder(override val codec: SessionAudioCodec) : RealtimeAudioEncoderInterface {
    override val inputPCMByteCount: Int = 4
    private val configuration = SessionAudioCodecConfiguration(codec, 16_000, 1, 20, 20_000)

    override fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket =
        NativeEncodedAudioPacket(configuration, pcm16LittleEndian.copyOf())

    override fun close() = Unit
}

private class BoundTestDecoder(
    override val configuration: SessionAudioCodecConfiguration,
) : RealtimeAudioDecoderInterface {
    override fun decode(packet: ByteArray): ByteArray = packet.copyOf()
    override fun close() = Unit
}
