package com.aessam.comeoverhere

import android.Manifest
import android.app.KeyguardManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.util.Log
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.aessam.comeoverhere.core.BluetoothDiscoveryMode
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.NearbyTCPConnection
import com.aessam.comeoverhere.core.WiFiAwareRoomTransport
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.NearbyLaneRequest
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AwarePhysicalBenchmarkTest {
    @get:Rule val permissions: GrantPermissionRule = GrantPermissionRule.grant(*(
        BluetoothRoomDiscovery.requiredPermissions().toList() +
            if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.NEARBY_WIFI_DEVICES) else emptyList()
        ).toTypedArray())

    @Test fun completionWaitsForPeerBeforeReleasingOwner() {
        val guide = mutableListOf<NearbyByteConnection>()
        val guest = mutableListOf<NearbyByteConnection>()
        val pool = Executors.newCachedThreadPool()
        try {
            repeat(4) {
                ServerSocket(0).use { server ->
                    guest.add(NearbyTCPConnection(Socket("127.0.0.1", server.localPort).apply { soTimeout = 5_000 }))
                    guide.add(NearbyTCPConnection(server.accept().apply { soTimeout = 5_000 }))
                }
            }
            val serving = pool.submit { AwareBenchmarkProtocol.guide(guide, pool) }
            val output = DataOutputStream(guest[0].output)
            val input = DataInputStream(guest[0].input)
            output.writeInt(0x47414231); output.flush()
            assertEquals(0x47414231, input.readInt())
            guest[3].close()
            output.writeInt(0); output.flush()
            assertEquals(0x47414231, input.readInt())
            assertThrows(TimeoutException::class.java) { serving.get(100, TimeUnit.MILLISECONDS) }
            guest[0].close()
            serving.get(5, TimeUnit.SECONDS)
        } finally { (guide + guest).forEach { it.close() }; pool.shutdownNow() }
    }

    @Test fun protocolLoopbackAndCorruptionSmoke() {
        val guide = mutableListOf<NearbyByteConnection>()
        val guest = mutableListOf<NearbyByteConnection>()
        val pool = Executors.newCachedThreadPool()
        try {
            repeat(4) {
                ServerSocket(0).use { server ->
                    guest.add(NearbyTCPConnection(Socket("127.0.0.1", server.localPort).apply { soTimeout = 10_000 }))
                    guide.add(NearbyTCPConnection(server.accept().apply { soTimeout = 10_000 }))
                }
            }
            val serving = pool.submit { AwareBenchmarkProtocol.guide(guide, pool) }
            val results = mutableListOf<JSONObject>()
            AwareBenchmarkProtocol.guest(guest, pool, 100, 1) { results.add(it) }
            serving.get(10, TimeUnit.SECONDS)
            assertEquals(5, results.size)
            assertEquals(2.0, AwareBenchmarkProtocol.percentile(listOf(1.0, 2.0, 3.0), .5), 0.0)
            assertThrows(IllegalStateException::class.java) {
                // Valid length/sequence, wrong payload; not a successful throughput sample.
                val bytes = byteArrayOf(0, 0, 0, 1) + ByteArray(8) + byteArrayOf(2)
                AwareBenchmarkProtocol.receive(DataInputStream(ByteArrayInputStream(bytes)), byteArrayOf(1))
            }
        } finally { (guide + guest).forEach { it.close() }; pool.shutdownNow() }
    }

    @Test fun tinyPacketLoopbackAndCorruptionSmoke() {
        val guide = mutableListOf<NearbyByteConnection>()
        val guest = mutableListOf<NearbyByteConnection>()
        val pool = Executors.newCachedThreadPool()
        try {
            repeat(4) {
                ServerSocket(0).use { server ->
                    guest.add(NearbyTCPConnection(Socket("127.0.0.1", server.localPort).apply { soTimeout = 10_000 }))
                    guide.add(NearbyTCPConnection(server.accept().apply { soTimeout = 10_000 }))
                }
            }
            val serving = pool.submit { AwareTinyPacketProtocol.guide(guide, pool) }
            val results = mutableListOf<JSONObject>()
            AwareTinyPacketProtocol.guest(guest, pool, 500, 1) { results.add(it) }
            serving.get(10, TimeUnit.SECONDS)
            assertEquals(listOf("tiny_idle", "tiny_paced_asset"), results.map { it.getString("phase") })
            results.forEach {
                assertEquals(it.getInt("offered_packets"), it.getInt("sent_packets") + it.getInt("local_schedule_drops"))
                assertEquals(it.getInt("sent_packets"), it.getInt("received_packets"))
                assertEquals(0, it.getInt("missing_echo_packets"))
            }
            val factory = AwareTinyPacketProtocol.FrameFactory()
            val frame = factory.frame(0, 1)
            factory.verifier.verify(frame)
            assertThrows(IllegalArgumentException::class.java) {
                factory.verifier.verify(frame.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() })
            }
            assertEquals(false, AwareTinyPacketProtocol.missedSlot(19_999_999, 0))
            assertEquals(true, AwareTinyPacketProtocol.missedSlot(20_000_000, 0))
            assertEquals(3.0, AwareBenchmarkProtocol.percentile(listOf(1.0, 2.0, 3.0), .99), 0.0)
        } finally { (guide + guest).forEach { it.close() }; pool.shutdownNow() }
    }

    @Test fun measurePhysicalAwareGoodput() {
        val args = InstrumentationRegistry.getArguments()
        val role = args.getString("benchmarkRole")
        assumeTrue("Explicit two-phone benchmark only", role == "guide" || role == "guest")
        assumeTrue("Requires physical Android Aware", Build.VERSION.SDK_INT >= 34 && !Build.FINGERPRINT.contains("generic"))
        val room = UUID.fromString(requireNotNull(args.getString("benchmarkRoom")))
        val token = UUID.fromString(requireNotNull(args.getString("benchmarkToken")))
        val pin = requireNotNull(args.getString("benchmarkPIN"))
        val millis = requireNotNull(args.getString("benchmarkMillis")).toInt()
        val rounds = requireNotNull(args.getString("benchmarkRounds")).toInt()
        val profile = args.getString("benchmarkProfile") ?: "bulk"
        require(profile in setOf("bulk", "tiny"))
        require(millis in 100..30_000 && rounds in 1..5 && pin.matches(Regex("[0-9]{6}")))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val power = context.getSystemService(PowerManager::class.java)
        val pool = Executors.newCachedThreadPool()
        val timer = Executors.newSingleThreadScheduledExecutor()
        val connections = CopyOnWriteArrayList<NearbyByteConnection>()
        val failure = AtomicReference<String?>()
        val focused = AtomicBoolean(false)
        val focusReady = CountDownLatch(1)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        var radio: WiFiAwareRoomTransport? = null
        var server: ServerSocket? = null
        val activity = ActivityScenario.launch(MainActivity::class.java)
        fun report(json: JSONObject) {
            json.put("role", role).put("model", Build.MODEL).put("sdk", Build.VERSION.SDK_INT)
                .put("thermal_status", power.currentThermalStatus)
                .put("benchmark_profile", profile).put("transport_path", "aware_tcp_guide_adapter")
            Log.i("AwareBenchmark", json.toString())
            instrumentation.sendStatus(0, Bundle().apply { putString("aware_benchmark", json.toString()) })
        }
        fun ensureForeground() {
            check(power.isInteractive && !keyguard.isKeyguardLocked && focused.get()) {
                "Benchmark requires an awake, unlocked foreground phone"
            }
        }
        try {
            val ready = CountDownLatch(1)
            activity.onActivity {
                it.window.decorView.viewTreeObserver.addOnWindowFocusChangeListener { hasFocus ->
                    focused.set(hasFocus)
                    if (hasFocus) focusReady.countDown()
                }
                focused.set(it.hasWindowFocus())
                if (focused.get()) focusReady.countDown()
                it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                it.setTurnScreenOn(true)
                if (keyguard.isKeyguardLocked) {
                    check(!keyguard.isKeyguardSecure) { "Unlock the secure phone manually; benchmark never supplies credentials" }
                    it.setShowWhenLocked(true)
                    keyguard.requestDismissKeyguard(it, object : KeyguardManager.KeyguardDismissCallback() {
                        override fun onDismissSucceeded() { it.setShowWhenLocked(false); ready.countDown() }
                        override fun onDismissError() { failure.set("Keyguard dismissal failed"); ready.countDown() }
                        override fun onDismissCancelled() { failure.set("Keyguard dismissal cancelled"); ready.countDown() }
                    })
                } else ready.countDown()
            }
            check(ready.await(5, TimeUnit.SECONDS)) { "Foreground setup timed out" }
            check(focusReady.await(5, TimeUnit.SECONDS)) { "Benchmark activity never obtained window focus" }
            check(failure.get() == null) { requireNotNull(failure.get()) }
            ensureForeground()
            report(JSONObject().put("phase", "foreground_ready").put("interactive", true).put("keyguard", false))
            val deadlineSeconds = 60L + rounds * 3L * (millis / 1_000 + 15)
            timer.schedule({
                failure.compareAndSet(null, "Benchmark total deadline expired")
                connections.forEach { it.close() }; server?.close()
            }, deadlineSeconds, TimeUnit.SECONDS)
            timer.scheduleAtFixedRate({
                if (!power.isInteractive || keyguard.isKeyguardLocked || !focused.get()) {
                    failure.compareAndSet(null, "Foreground lost during benchmark")
                    connections.forEach { it.close() }; server?.close()
                }
            }, 1, 1, TimeUnit.SECONDS)

            val discovered = CountDownLatch(1)
            val started = System.nanoTime()
            if (role == "guide") {
                server = ServerSocket().apply {
                    reuseAddress = true; soTimeout = 45_000
                    bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 50_002), 4)
                }
            }
            instrumentation.runOnMainSync {
                val owner = WiFiAwareRoomTransport(context) { pin }
                radio = owner
                owner.onError = { message ->
                    failure.compareAndSet(null, message); discovered.countDown()
                    Log.e("AwareBenchmark", "Native stage failure: $message")
                    connections.forEach { it.close() }; server?.close()
                }
                if (role == "guide") {
                    owner.publish(BluetoothRoomRecord(room, UUID.randomUUID(), "Aware benchmark (test)", true, false))
                    owner.setMode(BluetoothDiscoveryMode.ADVERTISING)
                } else {
                    owner.onRoom = { if (it.roomID == room) discovered.countDown() }
                    owner.setMode(BluetoothDiscoveryMode.BROWSING)
                    scope.launch {
                        val attempted = mutableSetOf<String>()
                        owner.state.collect { state ->
                            Log.i("AwareBenchmark", "Aware peers=${state.peers.size} enabled=${state.enabled}")
                            state.peers.forEach { peer -> if (attempted.add(peer.id)) owner.pair(peer.id, pin) }
                        }
                    }
                }
            }
            val channels = arrayOfNulls<NearbyByteConnection>(4)
            if (role == "guide") {
                repeat(4) {
                    val connection = NearbyTCPConnection(requireNotNull(server).accept().apply { soTimeout = 45_000 })
                    connections.add(connection)
                    val input = DataInputStream(connection.input)
                    check(UUID(input.readLong(), input.readLong()) == token) { "Unexpected benchmark client" }
                    val channel = input.readInt()
                    check(channel in 0..3 && channels[channel] == null) { "Invalid benchmark channel" }
                    channels[channel] = connection
                    DataOutputStream(connection.output).apply { writeInt(channel); flush() }
                }
            } else {
                check(discovered.await(35, TimeUnit.SECONDS)) { "Aware endpoint discovery timed out" }
                check(failure.get() == null) { requireNotNull(failure.get()) }
                report(JSONObject().put("phase", "discovered").put("elapsed_ms", (System.nanoTime() - started) / 1_000_000.0))
                lateinit var connect: () -> NearbyByteConnection
                instrumentation.runOnMainSync { connect = requireNotNull(radio).connector(room) }
                repeat(4) { channel ->
                    val connection = connect(); connections.add(connection)
                    connection.output.write(NearbyLaneRequest(NearbyLaneRequest.Lane.ASSET, room).encode())
                    connection.output.flush()
                    check(connection.input.read() == 0) { "Aware adapter rejected benchmark lane" }
                    DataOutputStream(connection.output).apply {
                        writeLong(token.mostSignificantBits); writeLong(token.leastSignificantBits); writeInt(channel); flush()
                    }
                    check(DataInputStream(connection.input).readInt() == channel)
                    channels[channel] = connection
                }
            }
            ensureForeground()
            val diagnostic = requireNotNull(radio).state.value.diagnostics
            report(JSONObject().put("phase", "connected").put("elapsed_ms", (System.nanoTime() - started) / 1_000_000.0)
                .put("maximum_data_paths", diagnostic.maximumDataPaths ?: JSONObject.NULL)
                .put("available_data_paths", diagnostic.availableDataPaths ?: JSONObject.NULL)
                .put("owned_network_handles", diagnostic.networks.map { it.networkHandle }.distinct().joinToString(","))
                .put("owned_interfaces", diagnostic.networks.mapNotNull { it.interfaceName }.distinct().joinToString(",")))
            val streams = channels.map { requireNotNull(it) }
            if (profile == "tiny") {
                if (role == "guide") AwareTinyPacketProtocol.guide(streams, pool)
                else AwareTinyPacketProtocol.guest(streams, pool, millis, rounds, ::report)
            } else {
                if (role == "guide") AwareBenchmarkProtocol.guide(streams, pool)
                else AwareBenchmarkProtocol.guest(streams, pool, millis, rounds, ::report)
            }
            check(failure.get() == null) { requireNotNull(failure.get()) }
            ensureForeground()
            report(JSONObject().put("phase", "complete").put("interactive", true).put("keyguard", false))
        } catch (error: Exception) {
            throw IllegalStateException(failure.get() ?: "Aware benchmark failed", error)
        } finally {
            timer.shutdownNow(); connections.forEach { it.close() }; server?.close()
            scope.cancel(); instrumentation.runOnMainSync { radio?.stop() }
            pool.shutdownNow(); activity.close()
        }
    }
}
