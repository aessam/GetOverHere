package com.aessam.comeoverhere

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.core.NativeRealtimeAudioCodecFactory
import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionCapability
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.sin

@RunWith(AndroidJUnit4::class)
class NativeRealtimeAudioCodecTest {
    @Test
    fun opusAndAacLcEncodeAndDecodeNativePcm16Frames() {
        SessionAudioCodec.entries.forEach(::assertCodecRoundtrip)
    }

    @Test
    fun nativeCapabilitiesMapToSessionNegotiationBits() {
        val capabilities = NativeRealtimeAudioCodecFactory.sessionCapabilities()
        SessionCapability.entries.forEach { capability ->
            assertTrue("missing ${capability.name}", capabilities and capability.bit != 0L)
        }
    }

    @Test
    fun nativeCodecCrossesEncryptedRealtimeTransport() {
        val port = 50_034
        val guide = UDPAudioPlane(audioPort = port)
        val guest = UDPAudioPlane(audioPort = port)
        val sessionID = UUID.randomUUID()
        val credential = SessionCredential.derive("23456789AB", sessionID)
        val joined = CountDownLatch(1)
        val audioReceived = CountDownLatch(1)
        try {
            guide.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guide",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guide.setSessionEventHandler { event ->
                if (event is AudioSessionEvent.Joined) joined.countDown()
            }
            guide.startBroadcasting(sessionID.toString(), AudioQuality.STANDARD)

            guest.hostIP = "127.0.0.1"
            guest.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                credential,
            )
            guest.startListening(sessionID.toString()) { pcm ->
                if (pcm.isNotEmpty() && pcm.size % Short.SIZE_BYTES == 0) audioReceived.countDown()
            }

            assertTrue("Native-codec guest did not join", joined.await(5, TimeUnit.SECONDS))
            repeat(12) { frameIndex -> guide.sendAudio(sineFrame(640, frameIndex)) }
            assertTrue("Decoded PCM did not cross the transport", audioReceived.await(5, TimeUnit.SECONDS))
        } finally {
            guest.stop()
            guide.stop()
        }
    }

    private fun assertCodecRoundtrip(codec: SessionAudioCodec) {
        val encoder = NativeRealtimeAudioCodecFactory.makeEncoder(codec)
        var decoder = null as RealtimeAudioDecoderInterface?
        var producedPacketCount = 0
        var encodedByteCount = 0
        var decodedByteCount = 0
        try {
            repeat(24) { frameIndex ->
                val pcm = sineFrame(encoder.inputPCMByteCount, frameIndex)
                val packet = encoder.encode(pcm) ?: return@repeat
                producedPacketCount += 1
                encodedByteCount += packet.bytes.size
                if (decoder == null) decoder = NativeRealtimeAudioCodecFactory.makeDecoder(packet.configuration)
                decoder?.decode(packet.bytes)?.let { decodedByteCount += it.size }
            }
            assertTrue("$codec produced no packets", producedPacketCount > 0)
            assertTrue("$codec produced no encoded bytes", encodedByteCount > 0)
            assertTrue("$codec produced no decoded bytes", decodedByteCount > 0)
            assertTrue("$codec did not compress PCM", encodedByteCount < 24 * encoder.inputPCMByteCount)
        } finally {
            decoder?.close()
            encoder.close()
        }
    }

    private fun sineFrame(byteCount: Int, frameIndex: Int): ByteArray {
        val sampleCount = byteCount / Short.SIZE_BYTES
        return ByteBuffer.allocate(byteCount).order(ByteOrder.LITTLE_ENDIAN).apply {
            repeat(sampleCount) { index ->
                val phase = (frameIndex * sampleCount + index) * 440.0 * 2.0 * PI / 16_000.0
                putShort((sin(phase) * Short.MAX_VALUE * 0.25).toInt().toShort())
            }
        }.array()
    }
}
