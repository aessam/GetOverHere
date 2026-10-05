package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyByteConnection
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.util.Arrays
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil
import org.json.JSONObject

/** Test-only deterministic bulk traffic. Never a tour wire protocol or an Internet speed test. */
internal object AwareBenchmarkProtocol {
    const val BLOCK_SIZE = 65_536
    private const val MAGIC = 0x47414231 // GAB1, test protocol only
    private val download = ByteArray(BLOCK_SIZE) { ((it * 31 + 17) and 255).toByte() }
    private val upload = ByteArray(BLOCK_SIZE) { ((it * 13 + 91) and 255).toByte() }

    data class Transfer(val sent: Long, val received: Long, val receiveNanos: Long) {
        val receiveMbps: Double get() = received * 8_000.0 / receiveNanos.coerceAtLeast(1)
    }

    fun receive(input: DataInputStream, expected: ByteArray): Pair<Long, Long> {
        val started = System.nanoTime()
        val block = ByteArray(expected.size)
        var sequence = 0L
        var total = 0L
        while (true) {
            val count = input.readInt()
            if (count == 0) return total to (System.nanoTime() - started)
            check(count == expected.size) { "Invalid benchmark block length" }
            check(input.readLong() == sequence++) { "Missing or duplicate benchmark block" }
            input.readFully(block)
            check(Arrays.equals(block, expected)) { "Corrupt benchmark payload" }
            total += count
        }
    }

    private fun send(output: DataOutputStream, block: ByteArray, millis: Int): Long {
        val deadline = System.nanoTime() + millis * 1_000_000L
        var sequence = 0L
        do {
            output.writeInt(block.size); output.writeLong(sequence++); output.write(block)
        } while (System.nanoTime() < deadline)
        output.writeInt(0); output.flush()
        return sequence * block.size
    }

    private fun transfer(channels: List<NearbyByteConnection>, pool: ExecutorService,
                         guide: Boolean, mode: Int, millis: Int): Transfer {
        require(mode in 1..3 && millis in 100..30_000)
        val writes = if (guide) mode != 2 else mode != 1
        val reads = if (guide) mode != 1 else mode != 2
        val writer = if (writes) pool.submit<Long> {
            val channel = channels[if (guide) 1 else 2]
            send(DataOutputStream(BufferedOutputStream(channel.output, BLOCK_SIZE * 2)),
                if (guide) download else upload, millis)
        } else null
        val reader = if (reads) pool.submit<Pair<Long, Long>> {
            receive(DataInputStream(channels[if (guide) 2 else 1].input), if (guide) upload else download)
        } else null
        val received = reader?.get(millis.toLong() + 15_000, TimeUnit.MILLISECONDS) ?: (0L to 0L)
        return Transfer(writer?.get(15, TimeUnit.SECONDS) ?: 0L, received.first, received.second)
    }

    private fun echo(channel: NearbyByteConnection) {
        val input = DataInputStream(channel.input)
        val output = DataOutputStream(channel.output)
        while (true) {
            val value = try { input.readInt() } catch (_: EOFException) { return }
            output.writeInt(value); output.flush()
        }
    }

    private fun ping(channel: NearbyByteConnection, active: AtomicBoolean, minimumSamples: Int = 1): List<Double> {
        val input = DataInputStream(channel.input)
        val output = DataOutputStream(channel.output)
        val samples = mutableListOf<Double>()
        var sequence = 0
        do {
            val started = System.nanoTime()
            output.writeInt(sequence); output.flush()
            check(input.readInt() == sequence++) { "Invalid benchmark echo" }
            samples.add((System.nanoTime() - started) / 1_000_000.0)
            Thread.sleep(20)
        } while (active.get() || samples.size < minimumSamples)
        return samples
    }

    fun percentile(values: List<Double>, quantile: Double): Double {
        require(values.isNotEmpty() && quantile > 0 && quantile <= 1)
        return values.sorted()[ceil(values.size * quantile).toInt() - 1]
    }

    fun guide(channels: List<NearbyByteConnection>, pool: ExecutorService) {
        require(channels.size == 4)
        val input = DataInputStream(channels[0].input)
        val output = DataOutputStream(channels[0].output)
        check(input.readInt() == MAGIC) { "Not a benchmark connection" }
        output.writeInt(MAGIC); output.flush()
        val echo = pool.submit { echo(channels[3]) }
        try {
            while (true) {
                val mode = input.readInt()
                if (mode == 0) break
                val millis = input.readInt()
                require(mode in 1..3 && millis in 100..30_000)
                output.writeInt(mode); output.flush()
                val result = transfer(channels, pool, true, mode, millis)
                output.writeLong(result.sent); output.writeLong(result.received)
                output.writeLong(result.receiveNanos); output.flush()
            }
            echo.get(5, TimeUnit.SECONDS)
            output.writeInt(MAGIC); output.flush()
            // Keep the native Aware owner alive until the guest consumes the final marker.
            // Completing a local TCP write does not mean the native bridge has delivered it.
            check(input.read() == -1) { "Unexpected data after benchmark completion" }
        } finally { channels[3].close() }
    }

    fun guest(channels: List<NearbyByteConnection>, pool: ExecutorService, millis: Int, rounds: Int,
              report: (JSONObject) -> Unit) {
        require(channels.size == 4 && millis in 100..30_000 && rounds in 1..5)
        val input = DataInputStream(channels[0].input)
        val output = DataOutputStream(channels[0].output)
        output.writeInt(MAGIC); output.flush()
        check(input.readInt() == MAGIC)
        val idle = pool.submit<List<Double>> { ping(channels[3], AtomicBoolean(false), minimumSamples = 100) }
        val idleSamples = idle.get(30, TimeUnit.SECONDS)
        report(JSONObject().put("phase", "idle").put("samples", idleSamples.size)
            .put("rtt_p50_ms", percentile(idleSamples, .50)).put("rtt_p95_ms", percentile(idleSamples, .95)))
        // A separate duplex warm-up is reported, never merged into measured trials.
        val trials = listOf(0 to 3) + (1..rounds).flatMap { round -> (1..3).map { round to it } }
        for ((round, mode) in trials) {
            output.writeInt(mode); output.writeInt(if (round == 0) 1_000 else millis); output.flush()
            check(input.readInt() == mode)
            val active = AtomicBoolean(true)
            val latency = pool.submit<List<Double>> { ping(channels[3], active) }
            val guest = try { transfer(channels, pool, false, mode, if (round == 0) 1_000 else millis) }
                finally { active.set(false) }
            val guide = Transfer(input.readLong(), input.readLong(), input.readLong())
            check(guest.sent == guide.received && guide.sent == guest.received) { "Sender/receiver byte totals differ" }
            val samples = latency.get(15, TimeUnit.SECONDS)
            report(JSONObject().put("phase", if (round == 0) "warmup" else listOf("", "guide_to_guest", "guest_to_guide", "duplex")[mode])
                .put("round", round).put("block_bytes", BLOCK_SIZE)
                .put("guide_to_guest_bytes", guest.received).put("guest_to_guide_bytes", guide.received)
                .put("guide_to_guest_receive_ns", guest.receiveNanos).put("guest_to_guide_receive_ns", guide.receiveNanos)
                .put("guide_to_guest_mbps", guest.receiveMbps).put("guest_to_guide_mbps", guide.receiveMbps)
                .put("rtt_samples", samples.size).put("rtt_p50_ms", percentile(samples, .50))
                .put("rtt_p95_ms", percentile(samples, .95)).put("rtt_max_ms", samples.max()))
        }
        channels[3].close()
        output.writeInt(0); output.flush()
        check(input.readInt() == MAGIC) { "Guide did not confirm completion" }
        channels[0].close()
    }
}
