package com.aessam.comeoverhere

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.aessam.comeoverhere.core.BluetoothDiscoveryMode
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import com.aessam.toursession.BluetoothRoomRecord
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in counterpart to the iPhone central's raw CoC opening probe. This only hosts the
 * production GATT/PSM listener, or a distinct-PSM test host: no application qualification is implied.
 */
@RunWith(AndroidJUnit4::class)
class BluetoothChannelProbeTest {
    @get:Rule val permissions: GrantPermissionRule =
        GrantPermissionRule.grant(*BluetoothRoomDiscovery.requiredPermissions())

    @Test fun hostNativeChannelsForExplicitIPhoneProbe() {
        val arguments = InstrumentationRegistry.getArguments()
        val style = arguments.getString("nearbyProbeStyle")
        assumeTrue("Requires an explicit native channel probe", arguments.getString("nearbyRole") == "guide" && style != null)
        require(style in setOf("queued", "sequential", "after_close", "distinct_psms")) { "Unknown native channel probe style" }
        assumeTrue("LE credit-based sockets require Android 10+", Build.VERSION.SDK_INT >= 29)
        assumeTrue("Physical Bluetooth required", !Build.FINGERPRINT.contains("generic") && !Build.MODEL.contains("Emulator"))
        val room = UUID.fromString(requireNotNull(arguments.getString("nearbyRoom")))
        val guide = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = ActivityScenario.launch(MainActivity::class.java)
        var radio: BluetoothRoomDiscovery? = null
        var distinctHost: DistinctPSMHost? = null
        try {
            activity.onActivity {
                val app = instrumentation.targetContext.applicationContext as ComeOverHereApp
                check(app.channelService.activeChannelID.value == null) { "End the current tour before native channel probing" }
                it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                it.setTurnScreenOn(true)
                val record = BluetoothRoomRecord(room, guide, "Native channel probe", true, false, admissionVersion = 2)
                if (style == "distinct_psms") {
                    val host = DistinctPSMHost(instrumentation.targetContext, record)
                    distinctHost = host
                    host.start()
                } else {
                    radio = BluetoothRoomDiscovery(instrumentation.targetContext).also { listener ->
                        listener.publish(record)
                        listener.setMode(BluetoothDiscoveryMode.ADVERTISING)
                    }
                }
            }
            distinctHost?.awaitReady()
            Log.i(TAG, "HOST_START_REQUESTED style=$style; native readiness is the advertiser success callback")
            Log.i(TAG, "Native CoC opening only; admission, audio and application lanes are not running")
            // The existing production bridge expires sockets without a GOD1 selector after 10 s.
            // The iPhone's simultaneous-open observation finishes within 3 s; hold discovery so it
            // can execute all requested native-only cases without changing any radio settings.
            CountDownLatch(1).await(45, TimeUnit.SECONDS)
            distinctHost?.verifyNoFailure()
            Log.i(TAG, "HOST_WINDOW_COMPLETE style=$style; inspect iPhone results, not an application media pass")
        } finally {
            try { instrumentation.runOnMainSync { try { radio?.stop() } finally { distinctHost?.close() } } }
            finally { activity.close() }
        }
    }

    /** Deliberately test-only: three independent public CoC listeners, no GOD1 selector/adapters.
     * Characteristic 0008 is exactly three UInt16 PSMs in network byte order. Production 0007
     * still exposes the first PSM, so the experiment changes only the requested native endpoint.
     */
    @SuppressLint("MissingPermission", "NewApi") // Opt-in test already grants Bluetooth permissions and requires API29+.
    private class DistinctPSMHost(private val context: Context, record: BluetoothRoomRecord) : AutoCloseable {
        private val handler = Handler(Looper.getMainLooper())
        private val manager = context.getSystemService(BluetoothManager::class.java)
        private val adapter = requireNotNull(manager.adapter) { "Bluetooth adapter unavailable" }
        private val advertiser = requireNotNull(adapter.bluetoothLeAdvertiser) { "Bluetooth advertising unavailable" }
        private val recordBytes = record.encode()
        private val listeners = mutableListOf<BluetoothServerSocket>()
        private val accepted = mutableListOf<BluetoothSocket>()
        private val socketLock = Any()
        private val ready = CountDownLatch(1)
        private val failure = AtomicReference<Exception?>()
        private val workers = Executors.newFixedThreadPool(3) { work ->
            Thread(work, "distinct-psm-probe").apply { isDaemon = true }
        }
        private var gatt: BluetoothGattServer? = null
        private var psmBytes = byteArrayOf()
        @Volatile private var closed = false
        @Volatile private var advertisingRequested = false

        fun start() {
            check(adapter.isEnabled) { "Bluetooth must already be enabled for this probe" }
            repeat(3) { listeners += adapter.listenUsingInsecureL2capChannel() }
            val psms = listeners.map { it.psm }
            check(psms.toSet().size == 3 && psms.all { it in 1..65535 }) { "Three distinct native PSMs were not allocated" }
            psmBytes = psms.flatMap { listOf((it shr 8).toByte(), it.toByte()) }.toByteArray()
            gatt = requireNotNull(manager.openGattServer(context, serverCallback)) { "Probe GATT server unavailable" }
            val service = BluetoothGattService(BluetoothRoomDiscovery.SERVICE_ID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            listOf(BluetoothRoomDiscovery.RECORD_ID, BluetoothRoomDiscovery.PSM_ID, DISTINCT_PSMS_ID).forEach { id ->
                check(service.addCharacteristic(BluetoothGattCharacteristic(id,
                    BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)))
            }
            check(requireNotNull(gatt).addService(service)) { "Probe service registration rejected" }
            listeners.forEach { listener -> workers.execute {
                try {
                    val socket = listener.accept()
                    synchronized(socketLock) {
                        if (closed) socket.close()
                        else {
                            accepted += socket
                            Log.i(TAG, "DISTINCT_PSM_ACCEPTED psm=${listener.psm}; retaining native channel without application data")
                        }
                    }
                } catch (error: Exception) {
                    // Closing the owned listener is the documented way to abort a blocked accept.
                    if (!closed) fail(error)
                }
            } }
        }

        fun awaitReady() {
            check(ready.await(10, TimeUnit.SECONDS)) { "Distinct PSM advertiser did not become ready" }
            verifyNoFailure()
        }

        fun verifyNoFailure() { failure.get()?.let { throw it } }

        private fun fail(error: Exception) {
            failure.compareAndSet(null, error)
            Log.e(TAG, "Distinct PSM probe failed (${error.javaClass.simpleName})")
            ready.countDown()
        }

        private val advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) { handler.post {
                if (closed) return@post
                Log.i(TAG, "DISTINCT_PSM_HOST_READY; three dynamic listeners advertised, not an application session")
                ready.countDown()
            } }
            override fun onStartFailure(errorCode: Int) { handler.post {
                advertisingRequested = false
                if (!closed) fail(IllegalStateException("Probe advertising failed: $errorCode"))
            } }
        }

        private val serverCallback = object : BluetoothGattServerCallback() {
            override fun onServiceAdded(status: Int, service: BluetoothGattService) { handler.post {
                if (closed) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail(IllegalStateException("Probe GATT registration failed: $status")); return@post
                }
                try {
                    advertisingRequested = true
                    advertiser.startAdvertising(AdvertiseSettings.Builder().setConnectable(true)
                        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build(),
                        AdvertiseData.Builder().addServiceUuid(ParcelUuid(BluetoothRoomDiscovery.SERVICE_ID)).build(), advertiseCallback)
                } catch (error: Exception) { fail(error) }
            } }

            override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int,
                characteristic: BluetoothGattCharacteristic) { handler.post {
                if (closed) return@post
                val server = gatt ?: return@post
                val bytes = when (characteristic.uuid) {
                    BluetoothRoomDiscovery.RECORD_ID -> recordBytes
                    BluetoothRoomDiscovery.PSM_ID -> psmBytes.copyOfRange(0, 2)
                    DISTINCT_PSMS_ID -> psmBytes
                    else -> null
                }
                try {
                    val sent = when {
                        bytes == null -> server.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null)
                        offset !in 0..bytes.size -> server.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                        else -> server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes.copyOfRange(offset, bytes.size))
                    }
                    check(sent) { "Probe GATT read response rejected" }
                } catch (error: Exception) { fail(error) }
            } }
        }

        override fun close() {
            if (closed) return
            closed = true
            var cleanupError: Exception? = null
            fun closing(action: () -> Unit) {
                try { action() }
                catch (error: Exception) {
                    Log.e(TAG, "Distinct PSM cleanup failed (${error.javaClass.simpleName})")
                    if (cleanupError == null) cleanupError = error else cleanupError?.addSuppressed(error)
                }
            }
            if (advertisingRequested) closing { advertiser.stopAdvertising(advertiseCallback) }
            closing { gatt?.close() }; gatt = null
            listeners.forEach { listener -> closing { listener.close() } }; listeners.clear()
            synchronized(socketLock) {
                accepted.forEach { socket -> closing { socket.close() } }; accepted.clear()
            }
            workers.shutdownNow()
            cleanupError?.let { throw it }
        }
    }

    private companion object {
        const val TAG = "BluetoothChannelProbe"
        val DISTINCT_PSMS_ID: UUID = UUID.fromString("A1B2C3D4-0008-0000-0000-000000000000")
    }
}
