package com.aessam.comeoverhere

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.toursession.EncodedAudioFramePayload
import com.aessam.toursession.hexToByteArray
import com.aessam.comeoverhere.core.NativeRealtimeAudioCodecFactory
import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.RealtimeAudioEncoderInterface
import com.aessam.comeoverhere.core.RealtimeAudioCodecProvider
import com.aessam.comeoverhere.core.NativeEncodedAudioPacket
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
    @Test fun decodesProductionApplePackets() {
        val packets = InstrumentationRegistry.getInstrumentation().context.assets
            .open("apple-native-codec.hex").bufferedReader().useLines { lines ->
                lines.map { EncodedAudioFramePayload.decode(it.hexToByteArray()) }.toList()
            }
        SessionAudioCodec.entries.forEach { codec ->
            val frames = packets.filter { it.configuration.codec == codec }
            assertTrue("Missing Apple $codec packets", frames.isNotEmpty())
            val decoder = NativeRealtimeAudioCodecFactory.makeDecoder(frames.first().configuration)
            var bytes = 0
            val decodedPCM = java.io.ByteArrayOutputStream()
            try {
                frames.forEach { frame -> decoder.decode(frame.encodedBytes)?.let { bytes += it.size; decodedPCM.write(it) } }
                assertTrue("Apple $codec produced no decoded audio", bytes > 0)
                val config = frames.first().configuration
                val frameBytes = (config.sampleRate * config.frameDurationMilliseconds / 1_000 * config.channelCount * 2).toInt()
                val expected = frames.size * frameBytes
                assertTrue("Apple $codec PCM duration mismatch: $bytes bytes, expected approximately $expected",
                    bytes in (expected - 2 * frameBytes)..(expected + 2 * frameBytes))
                val pcm = ByteBuffer.wrap(decodedPCM.toByteArray()).order(ByteOrder.LITTLE_ENDIAN)
                val samples = List(bytes / 2) { pcm.short.toInt() }.drop(frameBytes)
                val rms = kotlin.math.sqrt(samples.sumOf { it.toDouble() * it } / samples.size)
                assertTrue("Apple $codec decoded silence", rms > 1_000)
                val crossings = samples.zipWithNext().count { (a, b) -> a <= 0 && b > 0 }
                val frequency = crossings * 16_000.0 / samples.size
                assertTrue("Apple $codec changed tone frequency to $frequency Hz", kotlin.math.abs(frequency - 440) < 10)
            } finally { decoder.close() }
        }
    }

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
        assertEncryptedTransport(NativeRealtimeAudioCodecFactory)
    }

    @Test fun applePacketsCrossEncryptedRealtimeTransport() {
        val frames = InstrumentationRegistry.getInstrumentation().context.assets
            .open("apple-native-codec.hex").bufferedReader().useLines { lines ->
                lines.map { EncodedAudioFramePayload.decode(it.hexToByteArray()) }.toList()
            }
        val replay = object : RealtimeAudioCodecProvider by NativeRealtimeAudioCodecFactory {
            override fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface {
                val packets = frames.filter { it.configuration.codec == codec }
                return object : RealtimeAudioEncoderInterface {
                    override val codec = codec
                    override val inputPCMByteCount = if (codec == SessionAudioCodec.OPUS) 640 else 2_048
                    private var index = 0
                    override fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket {
                        val packet = packets[index++ % packets.size]
                        return NativeEncodedAudioPacket(packet.configuration, packet.encodedBytes)
                    }
                    override fun close() = Unit
                }
            }
        }
        assertEncryptedTransport(replay)
    }

    private fun assertEncryptedTransport(provider: RealtimeAudioCodecProvider) {
        val port = 50_034
        val guide = UDPAudioPlane(codecProvider = provider, audioPort = port)
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
                // Concealment emits silence too: only actual decoded tone proves this path.
                if (pcm.any { it != 0.toByte() } && pcm.size % Short.SIZE_BYTES == 0) audioReceived.countDown()
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
