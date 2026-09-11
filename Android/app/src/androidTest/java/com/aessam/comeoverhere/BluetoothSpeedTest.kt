package com.aessam.comeoverhere

import android.os.Bundle
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.aessam.comeoverhere.core.BluetoothDiscoveryMode
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.NearbyTCPConnection
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.NearbyLaneRequest
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Test-only GBB1: bounded, byte-verified half-duplex transfer and 64-byte echo RTT. */
class BluetoothSpeedTest {
    @get:Rule val permissions = GrantPermissionRule.grant(*BluetoothRoomDiscovery.requiredPermissions())

    @Test fun protocolSmoke() {
        val server = ServerSocket(0)
        val pool = java.util.concurrent.Executors.newSingleThreadExecutor()
        val guest = NearbyTCPConnection(java.net.Socket("127.0.0.1", server.localPort).apply { soTimeout = 5000 })
        val guide = NearbyTCPConnection(server.accept().apply { soTimeout = 5000 })
        try {
            val serving = pool.submit { serve(guide) }
            var reports = 0
            benchmark(guest, 1024) { reports++ }
            serving.get(5, TimeUnit.SECONDS)
            check(reports == 7)
        } finally { guest.close(); guide.close(); server.close(); pool.shutdownNow() }
    }

    @Test fun measure() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val role = args.getString("speedRole")
        assumeTrue("Explicit physical benchmark only", role == "guide" || role == "guest")
        val room = UUID.fromString(requireNotNull(args.getString("speedRoom")))
        val count = requireNotNull(args.getString("speedBytes")).toInt()
        require(count in 1024..262144 && count % 1024 == 0)
        val activity = ActivityScenario.launch(MainActivity::class.java)
        lateinit var radio: BluetoothRoomDiscovery
        var radioCreated = false
        var server: ServerSocket? = null
        var connection: NearbyByteConnection? = null
        val ready = CountDownLatch(1)
        try {
            activity.onActivity {
                it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                it.setTurnScreenOn(true)
                radio = BluetoothRoomDiscovery(it)
                radioCreated = true
            }
            if (role == "guide") {
                server = ServerSocket().apply {
                    reuseAddress = true; soTimeout = 60000
                    bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 50002))
                }
                instrumentation.runOnMainSync {
                    radio.publish(BluetoothRoomRecord(room, UUID.randomUUID(), "Bluetooth speed test", true, false))
                    radio.setMode(BluetoothDiscoveryMode.ADVERTISING)
                }
                connection = NearbyTCPConnection(server.accept().apply { soTimeout = 30000 })
            } else {
                instrumentation.runOnMainSync {
                    radio.onRoom = { if (it.roomID == room && radio.canConnect(room)) ready.countDown() }
                    radio.setMode(BluetoothDiscoveryMode.BROWSING)
                }
                assertTrue("BLE endpoint discovery", ready.await(60, TimeUnit.SECONDS))
                lateinit var connect: () -> NearbyByteConnection
                instrumentation.runOnMainSync { radio.setJoinedRoom(room); connect = radio.connector(room) }
                connection = connect()
                connection.output.write(NearbyLaneRequest(NearbyLaneRequest.Lane.ASSET, room).encode())
                connection.output.flush()
                check(connection.input.read() == 0)
            }
            val stream = requireNotNull(connection)
            // Closing the owned connection bounds blocked native reads/writes as well as protocol loops.
            val deadline = java.util.Timer(true)
            deadline.schedule(object : java.util.TimerTask() { override fun run() { stream.close() } }, 180000)
            try {
                if (role == "guide") serve(stream)
                else benchmark(stream, count) { row ->
                    instrumentation.sendStatus(0, Bundle().apply { putString("bluetooth_speed", row.toString()) })
                }
            } finally { deadline.cancel() }
        } finally {
            connection?.close(); server?.close()
            instrumentation.runOnMainSync { if (radioCreated) radio.stop() }
            activity.close()
        }
    }

    private fun payload(count: Int) = ByteArray(count) { ((it * 31 + 17) and 255).toByte() }
    private fun serve(connection: NearbyByteConnection) {
        val input = DataInputStream(connection.input)
        val output = DataOutputStream(connection.output)
        check(input.readInt() == 0x47424231); output.writeInt(0x47424231); output.flush()
        while (true) {
            val mode = input.readInt()
            if (mode == 0) { output.writeInt(0); output.flush(); check(input.read() == -1); return }
            val count = input.readInt()
            require(mode in 1..3 && count in 1..262144)
            output.writeInt(mode); output.flush()
            val data = payload(count)
            if (mode == 1) {
                output.write(data); output.flush(); check(input.readInt() == count)
            } else {
                val start = System.nanoTime()
                val received = ByteArray(count); input.readFully(received)
                val elapsed = System.nanoTime() - start
                check(received.contentEquals(data)) { "Corrupt payload" }
                if (mode == 3) output.write(received) else output.writeLong(elapsed)
                output.flush()
            }
        }
    }

    private fun benchmark(connection: NearbyByteConnection, count: Int, report: (JSONObject) -> Unit) {
        val input = DataInputStream(connection.input)
        val output = DataOutputStream(connection.output)
        output.writeInt(0x47424231); output.flush(); check(input.readInt() == 0x47424231)
        val samples = mutableListOf<Double>()
        repeat(50) {
            output.writeInt(3); output.writeInt(64); output.flush(); check(input.readInt() == 3)
            val start = System.nanoTime()
            output.write(payload(64)); output.flush()
            val echo = ByteArray(64); input.readFully(echo)
            samples.add((System.nanoTime() - start) / 1e6)
            check(echo.contentEquals(payload(64)))
        }
        report(JSONObject().put("phase", "idle_rtt").put("samples_ms", org.json.JSONArray(samples)))
        repeat(3) { round ->
            for (mode in 1..2) {
                output.writeInt(mode); output.writeInt(count); output.flush(); check(input.readInt() == mode)
                val elapsed: Long
                if (mode == 1) {
                    val received = ByteArray(count)
                    val start = System.nanoTime(); input.readFully(received); elapsed = System.nanoTime() - start
                    check(received.contentEquals(payload(count)))
                    output.writeInt(count); output.flush()
                } else {
                    output.write(payload(count)); output.flush(); elapsed = input.readLong()
                }
                report(JSONObject().put("phase", if (mode == 1) "guide_to_guest" else "guest_to_guide")
                    .put("round", round + 1).put("bytes", count).put("receive_ns", elapsed)
                    .put("mbps", count * 8000.0 / elapsed))
            }
        }
        output.writeInt(0); output.flush(); check(input.readInt() == 0)
        connection.close()
    }
}
