package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.toursession.EncodedAudioFramePayload
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.LockSupport
import org.json.JSONArray
import org.json.JSONObject

/** Transport timing only: real core serialization/signatures around synthetic codec-sized bytes.
 * Echo does not decode audio; RTT is not mouth-to-ear latency or a one-way measurement.
 */
internal object AwareTinyPacketProtocol {
    const val MAGIC = 0x47415431 // GAT1, test-only protocol
    const val PERIOD_NANOS = 20_000_000L
    const val LATE_NANOS = 150_000_000L // analysis threshold, not an acoustic acceptance criterion
    const val ASSET_BYTES_PER_SECOND = 524_288
    private const val ASSET_CHUNK = 16_384
    private const val MAX_FRAME = 4_096
    private val asset = ByteArray(ASSET_CHUNK) { ((it * 31 + 19) and 255).toByte() }

    class FrameFactory {
        private val session = UUID.randomUUID()
        private val guide = UUID.randomUUID()
        private val stream = UUID.randomUUID()
        private val signer = GuideFrameSigner(session, guide)
        private val sealer = SessionFrameSealer(SessionCredential.derive("23456789AB", session))
        val verifier = GuideFrameVerifier(signer.publicKey, session, guide)
        fun frame(sequence: Long, capturedNanos: Long): ByteArray {
            val payload = EncodedAudioFramePayload(
                SessionAudioCodecConfiguration(SessionAudioCodec.OPUS, 16_000, 1, 20, 20_000),
                capturedNanos, Math.addExact(capturedNanos, LATE_NANOS),
                ByteArray(50) { ((it * 17 + sequence) and 255).toByte() },
            )
            return signer.sign(sealer.seal(SessionEnvelope(lane = SessionLane.REALTIME,
                kind = SessionMessageKind.AUDIO_FRAME, sequence = sequence, sessionId = session,
                senderId = guide, payload = payload.encode()), stream)).encode()
        }
    }

    /** No catch-up bursts: missed slots are reported, never silently shifted to later time. */
    fun missedSlot(now: Long, due: Long): Boolean = now - due >= PERIOD_NANOS

    private fun waitUntil(deadline: Long) {
        while (true) {
            check(!Thread.currentThread().isInterrupted) { "Benchmark interrupted" }
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) return
            LockSupport.parkNanos(remaining)
        }
    }

    fun echo(channel: NearbyByteConnection) {
        val input = DataInputStream(channel.input)
        val output = DataOutputStream(channel.output)
        while (true) {
            val size = input.readInt()
            if (size == 0) { output.writeInt(0); output.flush(); return }
            check(size in 158..MAX_FRAME) { "Invalid tiny-packet length" }
            val sequence = input.readLong()
            check(sequence >= 0) { "Invalid tiny-packet sequence" }
            val frame = ByteArray(size).also(input::readFully)
            output.writeInt(size); output.writeLong(sequence); output.write(frame); output.flush()
        }
    }

    private fun sendAssets(channel: NearbyByteConnection, millis: Int): Long {
        val output = DataOutputStream(channel.output)
        val end = System.nanoTime() + millis * 1_000_000L
        var sequence = 0L
        while (System.nanoTime() < end) {
            val started = System.nanoTime()
            output.writeInt(asset.size); output.writeLong(sequence++); output.write(asset); output.flush()
            waitUntil(started + asset.size * 1_000_000_000L / ASSET_BYTES_PER_SECOND)
        }
        output.writeInt(0); output.flush()
        return sequence * asset.size
    }

    fun guide(channels: List<NearbyByteConnection>, pool: ExecutorService) {
        require(channels.size == 4)
        val input = DataInputStream(channels[0].input)
        val output = DataOutputStream(channels[0].output)
        check(input.readInt() == MAGIC) { "Not a tiny-packet benchmark" }
        output.writeInt(MAGIC); output.flush()
        while (true) {
            val mode = input.readInt()
            if (mode == 0) break
            val millis = input.readInt()
            require(mode in 1..2 && millis in 100..30_000)
            val echo = pool.submit { echo(channels[3]) }
            output.writeInt(mode); output.flush()
            val assets = if (mode == 2) pool.submit<Long> { sendAssets(channels[1], millis) } else null
            echo.get(millis.toLong() + 10_000, TimeUnit.MILLISECONDS)
            output.writeLong(assets?.get(10, TimeUnit.SECONDS) ?: 0); output.flush()
        }
        output.writeInt(MAGIC); output.flush()
        check(input.read() == -1) { "Unexpected bytes after tiny-packet completion" }
    }

    private data class Sent(val bytes: ByteArray, val started: Long)

    fun guest(channels: List<NearbyByteConnection>, pool: ExecutorService, millis: Int, rounds: Int,
        report: (JSONObject) -> Unit) {
        require(channels.size == 4 && millis in 100..30_000 && rounds in 1..5)
        val factory = FrameFactory() // PBKDF2/setup is outside measured phases.
        val controlIn = DataInputStream(channels[0].input)
        val controlOut = DataOutputStream(channels[0].output)
        controlOut.writeInt(MAGIC); controlOut.flush(); check(controlIn.readInt() == MAGIC)
        var nextSequence = 0L
        for (round in 1..rounds) for (mode in 1..2) {
            controlOut.writeInt(mode); controlOut.writeInt(millis); controlOut.flush()
            check(controlIn.readInt() == mode)
            val assets = if (mode == 2) pool.submit<Pair<Long, Long>> {
                AwareBenchmarkProtocol.receive(DataInputStream(channels[1].input), asset)
            } else null
            val sent = ConcurrentHashMap<Long, Sent>()
            val samples = mutableListOf<Double>()
            val sequences = mutableSetOf<Long>()
            val receiver = pool.submit {
                val input = DataInputStream(channels[3].input)
                while (true) {
                    val size = input.readInt()
                    if (size == 0) break
                    check(size in 158..MAX_FRAME) { "Invalid echoed frame size" }
                    val sequence = input.readLong()
                    val bytes = ByteArray(size).also(input::readFully)
                    val received = System.nanoTime()
                    val expected = checkNotNull(sent[sequence]) { "Unsent echo sequence" }
                    check(sequences.add(sequence) && expected.bytes.contentEquals(bytes)) { "Duplicate/corrupt echo" }
                    samples.add((received - expected.started) / 1_000_000.0)
                }
            }
            val output = DataOutputStream(channels[3].output)
            val offered = millis / 20
            var dropped = 0
            val serialization = mutableListOf<Double>()
            val sendLags = mutableListOf<Double>()
            val started = System.nanoTime()
            try {
                repeat(offered) { slot ->
                    val due = started + slot * PERIOD_NANOS
                    waitUntil(due)
                    if (missedSlot(System.nanoTime(), due)) { dropped++; return@repeat }
                    val before = System.nanoTime()
                    val sequence = nextSequence++
                    val frame = factory.frame(sequence, due)
                    val sending = System.nanoTime()
                    serialization.add((sending - before) / 1_000_000.0)
                    if (missedSlot(sending, due)) { dropped++; return@repeat }
                    sent[sequence] = Sent(frame, sending)
                    sendLags.add((sending - due) / 1_000_000.0)
                    output.writeInt(frame.size); output.writeLong(sequence); output.write(frame); output.flush()
                }
                output.writeInt(0); output.flush()
                receiver.get(10, TimeUnit.SECONDS)
                val receivedAssets = assets?.get(10, TimeUnit.SECONDS) ?: (0L to 0L)
                check(controlIn.readLong() == receivedAssets.first) { "Asset byte counts disagree" }
                check(sent.isNotEmpty() && sequences.size == sent.size) { "Missing tiny-packet echoes" }
                val late = samples.count { it >= LATE_NANOS / 1_000_000.0 }
                report(JSONObject().put("phase", if (mode == 1) "tiny_idle" else "tiny_paced_asset")
                    .put("round", round).put("offered_packets", offered).put("sent_packets", sent.size)
                    .put("received_packets", samples.size).put("missing_echo_packets", sent.size - samples.size)
                    .put("local_schedule_drops", dropped).put("late_echo_packets", late).put("late_threshold_ms", 150)
                    .put("offered_pps", 50).put("duration_ms", millis)
                    .put("signed_frame_bytes", sent.values.first().bytes.size).put("probe_prefix_bytes", 12)
                    .put("asset_target_bytes_per_second", if (mode == 2) ASSET_BYTES_PER_SECOND else 0)
                    .put("asset_received_bytes", receivedAssets.first).put("asset_receive_ns", receivedAssets.second)
                    .put("rtt_p50_ms", AwareBenchmarkProtocol.percentile(samples, .50))
                    .put("rtt_p95_ms", AwareBenchmarkProtocol.percentile(samples, .95))
                    .put("rtt_p99_ms", AwareBenchmarkProtocol.percentile(samples, .99)).put("rtt_max_ms", samples.max())
                    .put("serialization_p95_ms", AwareBenchmarkProtocol.percentile(serialization, .95))
                    .put("send_lag_p95_ms", AwareBenchmarkProtocol.percentile(sendLags, .95))
                    .put("rtt_samples_ms", JSONArray(samples)).put("send_lag_samples_ms", JSONArray(sendLags))
                    .put("scope", "aware_tcp_guide_adapter_synthetic_audio_framing")
                    .put("codec_or_acoustic_measurement", false))
            } catch (error: Exception) {
                // Closing bounded test-owned streams unblocks outstanding reads/writes before rethrowing.
                channels[1].close(); channels[3].close(); receiver.cancel(true); assets?.cancel(true)
                throw error
            }
        }
        controlOut.writeInt(0); controlOut.flush(); check(controlIn.readInt() == MAGIC)
        channels[0].close()
    }
}
