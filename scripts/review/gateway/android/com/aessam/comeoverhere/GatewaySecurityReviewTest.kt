package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.BoundedSocketFrameWriter
import com.aessam.comeoverhere.core.NativeEncodedAudioPacket
import com.aessam.comeoverhere.core.RealtimeAudioCodecProvider
import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.RealtimeAudioEncoderInterface
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.comeoverhere.core.SocketFrameOverflowPolicy
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.GatewayPairingMessage
import com.aessam.toursession.GatewayPairingRole
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionCredential
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deliberately red on ec1b0b8. Invoked only through the review init script. */
class GatewaySecurityReviewTest {
    @Test fun freshOfferSurvivesTenSecondCompanionClockSkew() {
        val offer = GatewayPairingMessage(GatewayPairingRole.OFFER, UUID.randomUUID(), UUID.randomUUID(),
            UUID.randomUUID(), 1_120_000L, ByteArray(32) { 1 }, ByteArray(32) { 2 },
            ByteArray(32) { 1 }, "192.0.2.1", 50104)
        // Issued at 1,000,000; scanned 3s later by a companion 10s behind.
        offer.validateReceivedOffer(993_000L)
    }

    @Test fun failedCodecCanBeReplacedWithoutEndingTour() = exerciseEncoder(fatal = true)
    @Test fun permanentlyStalledCodecCanBeReplacedWithoutEndingTour() = exerciseEncoder(fatal = false)

    private fun exerciseEncoder(fatal: Boolean) {
        val clock = AtomicLong(0)
        val created = AtomicInteger()
        val calls = LinkedBlockingQueue<Unit>()
        val closed = CountDownLatch(1)
        val outputs = AtomicInteger()
        val provider = object : RealtimeAudioCodecProvider {
            override fun sessionCapabilities() = 0L
            override fun makeDecoder(configuration: SessionAudioCodecConfiguration): RealtimeAudioDecoderInterface =
                error("No decoder in this capture-owner regression")
            override fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface {
                val index = created.incrementAndGet()
                return object : RealtimeAudioEncoderInterface {
                    override val codec = SessionAudioCodec.OPUS
                    override val inputPCMByteCount = 4
                    override fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket? {
                        calls.add(Unit)
                        if (index == 1) {
                            if (fatal) throw IllegalStateException("Injected terminal encoder failure")
                            return null
                        }
                        return NativeEncodedAudioPacket(SessionAudioCodecConfiguration(
                            codec, 16000, 1, 20, 16000, byteArrayOf()), pcm16LittleEndian)
                    }
                    override fun drainOutput(): NativeEncodedAudioPacket? { calls.add(Unit); return null }
                    override fun close() { closed.countDown() }
                }
            }
        }
        val room = UUID.randomUUID()
        val unusedWriter = BoundedSocketFrameWriter(Socket(), 1, "review-no-socket-writes", 1,
            SocketFrameOverflowPolicy.DROP_OLDEST, 100) { _, _ -> error("Unexpected socket write") }
        val processor = UDPAudioPlane.BroadcastProcessor(UDPAudioPlane.SessionConfiguration(room, UUID.randomUUID(),
            "Review fixture", ParticipantPlatform.ANDROID, SessionCredential.derive("23456789AB", room),
            SessionGuideAuthentication.LegacyFixture), provider, { 1_000_000_000L + clock.get() }, clock::get,
            { _, _ -> outputs.incrementAndGet() })
        try {
            repeat(24) {
                clock.addAndGet(250_000_000L)
                processor.submit(byteArrayOf(1, 2, 3, 4), mapOf(SessionAudioCodec.OPUS to listOf(unusedWriter)))
                assertTrue("Capture worker did not reach the actual encoder", calls.poll(3, TimeUnit.SECONDS) != null)
            }
            assertTrue("No replacement after 24 submissions across 6s of virtual time: created=${created.get()}, " +
                "outputs=${outputs.get()}, resets=${processor.encoderResetCount}", created.get() > 1)
        } finally {
            processor.stop(); unusedWriter.close()
            assertTrue("Review encoder resource not released", closed.await(3, TimeUnit.SECONDS))
        }
    }
}
