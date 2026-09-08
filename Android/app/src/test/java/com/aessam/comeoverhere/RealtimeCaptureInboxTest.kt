package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.BoundedSocketFrameWriter
import com.aessam.comeoverhere.core.NativeEncodedAudioPacket
import com.aessam.comeoverhere.core.RealtimeAudioCodecProvider
import com.aessam.comeoverhere.core.RealtimeAudioDecoderInterface
import com.aessam.comeoverhere.core.RealtimeAudioEncoderInterface
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.comeoverhere.core.SocketFrameOverflowPolicy
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.EncodedAudioFramePayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class RealtimeCaptureInboxTest {
    @Test fun invalidOrOversizedInputIsRejectedBeforeRetainingOrEncoding() {
        val provider = InboxCodecProvider { _, _, pcm -> inboxPacket(pcm) }
        val h = InboxHarness(provider)
        try {
            h.submit(byteArrayOf())
            h.submit(byteArrayOf(1))
            h.submit(ByteArray(32_002))
            assertEquals(3L, h.processor.droppedCaptureEntries)
            assertEquals(0, h.processor.pendingCaptureEntries)
            assertTrue(provider.encoders.isEmpty())
        } finally { h.close() }
    }

    @Test fun retainedNativeInputsAreBoundedAndOverflowResetsEncoder() {
        val supplied = java.util.concurrent.LinkedBlockingQueue<Int>()
        val provider = InboxCodecProvider { instance, call, pcm ->
            if (instance == 1) { supplied.add(call); null } else inboxPacket(pcm)
        }
        val h = InboxHarness(provider)
        try {
            repeat(8) { index ->
                h.submit(byteArrayOf(1, 2, 3, 4))
                assertEquals(index + 1, supplied.poll(3, TimeUnit.SECONDS))
            }
            h.submit(byteArrayOf(5, 6, 7, 8))
            assertTrue(provider.firstClosed.await(3, TimeUnit.SECONDS))
            h.submit(byteArrayOf(9, 10, 11, 12))
            assertTrue(h.output.await(3, TimeUnit.SECONDS))
            assertEquals(8, provider.encoders.first().calls)
            assertArrayEquals(byteArrayOf(9, 10, 11, 12), h.payloads().single().encodedBytes)
        } finally { h.close() }
    }

    @Test fun slowEncoderRetainsAtMostEightEntriesAndStopDropsAllOutputs() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val provider = InboxCodecProvider { _, _, pcm ->
            entered.countDown()
            check(release.await(3, TimeUnit.SECONDS))
            inboxPacket(pcm)
        }
        val h = InboxHarness(provider)
        try {
            h.submit(byteArrayOf(1, 2, 3, 4))
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            repeat(12) { h.submit(byteArrayOf(5, 6, 7, 8)) }
            assertEquals(8, h.processor.pendingCaptureEntries)
            assertEquals(4, h.processor.droppedCaptureEntries)
            h.processor.stop()
            h.processor.stop()
            assertEquals(0, h.processor.pendingCaptureEntries)
            release.countDown()
            assertTrue(provider.firstClosed.await(3, TimeUnit.SECONDS))
            assertTrue(h.frames.isEmpty())
            assertEquals(1, provider.encoders.single().closeCount)
        } finally { release.countDown(); h.close() }
    }

    @Test fun staleEncoderOutputIsDroppedAndQueuedExpiredInputIsNeverEncoded() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val provider = InboxCodecProvider { _, _, pcm ->
            entered.countDown(); check(release.await(3, TimeUnit.SECONDS)); inboxPacket(pcm)
        }
        val h = InboxHarness(provider)
        try {
            h.submit(byteArrayOf(1, 2, 3, 4))
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            h.submit(byteArrayOf(5, 6, 7, 8))
            h.time.set(200_000_000)
            release.countDown()
            assertTrue(provider.firstClosed.await(3, TimeUnit.SECONDS))
            h.processor.stop()
            assertTrue(h.frames.isEmpty())
            assertEquals(1, provider.encoders.sumOf { it.calls })
        } finally { release.countDown(); h.close() }
    }

    @Test fun bufferedNilOutputRetainsOldestSuppliedTimestamp() {
        val provider = InboxCodecProvider { _, call, pcm -> if (call == 1) null else inboxPacket(pcm) }
        val h = InboxHarness(provider)
        try {
            h.submit(byteArrayOf(1, 2, 3, 4))
            h.time.set(20_000_000)
            h.submit(byteArrayOf(5, 6, 7, 8))
            assertTrue(h.output.await(3, TimeUnit.SECONDS))
            val payload = h.payloads().single()
            assertEquals(InboxHarness.WALL_BASE, payload.capturedAtNanoseconds)
            assertEquals(InboxHarness.WALL_BASE + 500_000_000, payload.expiresAtNanoseconds)
        } finally { h.close() }
    }

    @Test fun expiredBufferedNilInputRecreatesEncoderBeforeFreshInput() {
        val firstInput = CountDownLatch(1)
        val provider = InboxCodecProvider { instance, _, pcm ->
            if (instance == 1) { firstInput.countDown(); null } else inboxPacket(pcm)
        }
        val h = InboxHarness(provider)
        try {
            h.submit(byteArrayOf(1, 2, 3, 4))
            assertTrue(firstInput.await(3, TimeUnit.SECONDS))
            h.time.set(200_000_000)
            h.submit(byteArrayOf(5, 6, 7, 8))
            assertTrue(h.output.await(3, TimeUnit.SECONDS))
            assertEquals(2, provider.encoders.size)
            assertEquals(1, provider.encoders.first().closeCount)
            val payload = h.payloads().single()
            assertArrayEquals(byteArrayOf(5, 6, 7, 8), payload.encodedBytes)
            assertEquals(InboxHarness.WALL_BASE + 200_000_000, payload.capturedAtNanoseconds)
        } finally { h.close() }
    }

    @Test fun mixedPartialUsesOldOriginOnlyForTheFirstPacket() {
        val h = InboxHarness(InboxCodecProvider { _, _, pcm -> inboxPacket(pcm) }, expectedOutputs = 3)
        try {
            h.submit(byteArrayOf(1, 2))
            h.time.set(20_000_000)
            h.submit(ByteArray(10) { 9 })
            assertTrue(h.output.await(3, TimeUnit.SECONDS))
            assertEquals(listOf(0L, 20_000_000L, 20_000_000L),
                h.payloads().map { it.capturedAtNanoseconds - InboxHarness.WALL_BASE })
        } finally { h.close() }
    }

    @Test fun discontinuityRecreatesCodecWithoutResettingSequenceOrStream() {
        val h = InboxHarness(InboxCodecProvider { _, _, pcm -> inboxPacket(pcm) })
        try {
            h.submit(byteArrayOf(1, 2, 3, 4))
            assertTrue(h.output.await(3, TimeUnit.SECONDS))
            val second = CountDownLatch(1)
            h.afterOutput = { if (h.frames.size == 2) second.countDown() }
            h.submit(byteArrayOf()) // Explicitly rejected gap, not an encodable frame.
            h.submit(byteArrayOf(5, 6, 7, 8))
            assertTrue(second.await(3, TimeUnit.SECONDS))
            val sealed = h.frames.map(SealedSessionEnvelope::decode)
            assertEquals(sealed.first().streamId, sealed.last().streamId)
            val opener = SessionFrameOpener(h.credential)
            val sequence = sealed.map { (opener.open(it) as SessionFrameOpenResult.Opened).envelope.sequence }
            assertEquals(listOf(0L, 1L), sequence)
        } finally { h.close() }
    }
}

private class InboxHarness(provider: InboxCodecProvider, expectedOutputs: Int = 1) : AutoCloseable {
    companion object { const val WALL_BASE = 1_000_000_000L }
    val time = AtomicLong(0)
    val frames = CopyOnWriteArrayList<ByteArray>()
    val output = CountDownLatch(expectedOutputs)
    @Volatile var afterOutput: (() -> Unit)? = null
    private val room = UUID.randomUUID()
    val credential = SessionCredential.derive("23456789AB", room)
    private val writer = BoundedSocketFrameWriter(Socket(), 1, "inbox-test-unused-socket", 1,
        SocketFrameOverflowPolicy.DROP_OLDEST, 100) { _, _ -> error("No socket writes in processor component test") }
    val processor = UDPAudioPlane.BroadcastProcessor(
        UDPAudioPlane.SessionConfiguration(room, UUID.randomUUID(), "Guide", ParticipantPlatform.ANDROID,
            credential, SessionGuideAuthentication.LegacyFixture), provider,
        wallClock = { WALL_BASE + time.get() }, monotonicClock = time::get,
        emitFrame = { bytes, _ -> frames += bytes; output.countDown(); afterOutput?.invoke() },
    )
    fun submit(bytes: ByteArray) = processor.submit(bytes, mapOf(SessionAudioCodec.OPUS to listOf(writer)))
    fun payloads(): List<EncodedAudioFramePayload> {
        val opener = SessionFrameOpener(credential)
        return frames.map { bytes ->
            val envelope = (opener.open(SealedSessionEnvelope.decode(bytes)) as SessionFrameOpenResult.Opened).envelope
            EncodedAudioFramePayload.decode(envelope.payload)
        }
    }
    override fun close() { processor.stop(); writer.close() }
}

private class InboxCodecProvider(private val action: (Int, Int, ByteArray) -> NativeEncodedAudioPacket?) : RealtimeAudioCodecProvider {
    val encoders = CopyOnWriteArrayList<Encoder>()
    val firstClosed = CountDownLatch(1)
    override fun sessionCapabilities() = 0L
    override fun makeEncoder(codec: SessionAudioCodec): RealtimeAudioEncoderInterface =
        Encoder(encoders.size + 1).also { encoders += it }
    override fun makeDecoder(configuration: SessionAudioCodecConfiguration): RealtimeAudioDecoderInterface = error("Not a decoder test")
    inner class Encoder(private val instance: Int) : RealtimeAudioEncoderInterface {
        @Volatile var calls = 0
        @Volatile var closeCount = 0
        override val codec = SessionAudioCodec.OPUS
        override val inputPCMByteCount = 4
        override fun encode(pcm16LittleEndian: ByteArray): NativeEncodedAudioPacket? {
            calls++
            return action(instance, calls, pcm16LittleEndian)
        }
        override fun close() { closeCount++; firstClosed.countDown() }
    }
}

private fun inboxPacket(bytes: ByteArray) = NativeEncodedAudioPacket(
    SessionAudioCodecConfiguration(SessionAudioCodec.OPUS, 16_000, 1, 20, 16_000, byteArrayOf()), bytes,
)
