package com.aessam.comeoverhere.core

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import com.aessam.toursession.BluetoothLanePSMs
import com.aessam.toursession.BluetoothRoomRecord
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap

interface BluetoothRoomDiscoveryInterface {
    var onRoom: ((BluetoothRoomRecord) -> Unit)?
    var onLost: ((UUID) -> Unit)?
    fun setMode(mode: BluetoothDiscoveryMode)
    fun stop()
    fun publish(record: BluetoothRoomRecord?)
}

interface BluetoothSessionDiscoveryInterface : BluetoothRoomDiscoveryInterface {
    fun canConnect(roomID: UUID): Boolean
    fun connector(roomID: UUID): () -> NearbyByteConnection
    fun setJoinedRoom(roomID: UUID?)
}

/** Read-only room metadata. All mutable state is serialized on the main handler. */
@SuppressLint("MissingPermission") // Every radio start and refresh checks all runtime permissions.
class BluetoothRoomDiscovery(private val context: Context,
    connectionBudget: NearbyConnectionBudget = NearbyConnectionBudget.sharedApp) : BluetoothSessionDiscoveryInterface {
    override var onRoom: ((BluetoothRoomRecord) -> Unit)? = null
    override var onLost: ((UUID) -> Unit)? = null
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var adapter: BluetoothAdapter? = null
    private var server: BluetoothGattServer? = null
    private var running = false
    private var mode = BluetoothDiscoveryMode.OFF
    private var retryAt = 0L
    private var radioStarted = false
    private var serviceReady = false
    private var advertising = false
    @Volatile private var record = byteArrayOf()
    private val links = mutableMapOf<String, BluetoothGatt>()
    private val characteristics = mutableMapOf<String, BluetoothGattCharacteristic>()
    private val pending = mutableMapOf<String, Long>()
    private val attempts = mutableMapOf<String, Long>()
    private val rooms = mutableMapOf<String, Pair<BluetoothRoomRecord, Long>>()
    private val snapshots = mutableMapOf<String, Pair<ByteArray, Long>>()
    private val sessionServers = mutableListOf<BluetoothServerSocket>()
    private var localLanePSMs: BluetoothLanePSMs? = null
    private val peerPSMs = mutableMapOf<String, Int>()
    private var joinedRoom: UUID? = null
    private var scanning = false
    private data class Endpoint(val device: BluetoothDevice, val psm: Int)
    private val roomEndpoints = ConcurrentHashMap<UUID, Endpoint>()
    private val connectLock = Any()
    private val sessionBridge = NearbySocketBridge(connectionBudget = connectionBudget)
    private val io = Executors.newCachedThreadPool { work -> Thread(work, "bluetooth-room").apply { isDaemon = true } }

    override fun canConnect(roomID: UUID): Boolean = Build.VERSION.SDK_INT >= 29 &&
        rooms.any { (address, record) -> record.first.roomID == roomID && peerPSMs.containsKey(address) && links.containsKey(address) }
    override fun setJoinedRoom(roomID: UUID?) {
        joinedRoom = roomID
        if (!permitted()) return
        links.forEach { (address, gatt) ->
            val priority = if (roomID != null && rooms[address]?.first?.roomID == roomID)
                BluetoothGatt.CONNECTION_PRIORITY_HIGH else BluetoothGatt.CONNECTION_PRIORITY_BALANCED
            if (!gatt.requestConnectionPriority(priority)) Log.w(TAG, "Bluetooth connection priority request rejected")
        }
        if (roomID != null) stopScanning()
        else if (running && mode == BluetoothDiscoveryMode.BROWSING) startScanning()
    }
    override fun connector(roomID: UUID): () -> NearbyByteConnection {
        check(Build.VERSION.SDK_INT >= 29) { "Bluetooth session connections require Android 10 or later" }
        check(roomEndpoints.containsKey(roomID)) { "Bluetooth room is no longer reachable" }
        return {
            if (Build.VERSION.SDK_INT < 29) error("Bluetooth session connections require Android 10 or later")
            synchronized(connectLock) {
                val endpoint = requireNotNull(roomEndpoints[roomID]) { "Bluetooth route is reconnecting" }
                val socket = endpoint.device.createInsecureL2capChannel(endpoint.psm)
                val timeout = Runnable { try { socket.close() } catch (error: Exception) { Log.w(TAG, "Bluetooth connect timeout close failed (${error.javaClass.simpleName})") } }
                handler.postDelayed(timeout, 8_000)
                try { socket.connect(); BluetoothByteConnection(socket) }
                catch (error: Exception) { socket.close(); throw error }
                finally { handler.removeCallbacks(timeout) }
            }
        }
    }

    private class BluetoothByteConnection(private val socket: BluetoothSocket) : NearbyByteConnection {
        override val input get() = socket.inputStream
        override val output get() = socket.outputStream
        override fun close() = socket.close()
    }

    companion object {
        private const val TAG = "BluetoothRoomDiscovery"
        val SERVICE_ID: UUID = UUID.fromString("A1B2C3D4-0005-0000-0000-000000000000")
        val RECORD_ID: UUID = UUID.fromString("A1B2C3D4-0006-0000-0000-000000000000")
        val PSM_ID: UUID = UUID.fromString("A1B2C3D4-0007-0000-0000-000000000000")
        val LANE_PSMS_ID: UUID = UUID.fromString("A1B2C3D4-0009-0000-0000-000000000000")
        fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
        ) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun permitted() = requiredPermissions().all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }
    private fun now() = SystemClock.elapsedRealtime()

    override fun setMode(mode: BluetoothDiscoveryMode) {
        if (this.mode == mode) return
        val savedRecord = record
        stop()
        record = savedRecord
        this.mode = mode
        if (mode == BluetoothDiscoveryMode.OFF) return
        running = true; handler.post(refresh)
    }
    override fun stop() {
        joinedRoom = null
        mode = BluetoothDiscoveryMode.OFF; retryAt = 0
        running = false; record = byteArrayOf(); handler.removeCallbacks(refresh); stopRadio()
    }
    override fun publish(record: BluetoothRoomRecord?) {
        this.record = try { record?.encode() ?: byteArrayOf() }
        catch (error: Exception) { Log.e(TAG, "Room metadata rejected (${error.javaClass.simpleName})"); byteArrayOf() }
        if (permitted()) updateAdvertising()
    }

    private val refresh = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                if (!permitted()) {
                    if (radioStarted) stopRadio()
                } else {
                    adapter = manager.adapter
                    if (adapter?.isEnabled != true) { if (radioStarted) stopRadio() }
                    else {
                        if (!radioStarted && now() >= retryAt) startRadio()
                        if (mode == BluetoothDiscoveryMode.BROWSING && joinedRoom?.let { !canConnect(it) } == true) startScanning()
                        updateAdvertising()
                        val time = now()
                        pending.filterValues { time - it > 9_000 }.keys.toList().forEach(::disconnect)
                        characteristics.toMap().forEach { (address, ch) ->
                            if (!pending.containsKey(address)) {
                                pending[address] = time
                                if (links[address]?.readCharacteristic(ch) != true) disconnect(address)
                            }
                        }
                        rooms.filterValues { time - it.second > 12_000 }.keys.toList().forEach { address ->
                            rooms.remove(address)?.let { onLost?.invoke(it.first.roomID) }
                        }
                        attempts.entries.removeAll { time - it.value > 12_000 }
                        snapshots.entries.removeAll { time - it.value.second > 10_000 }
                    }
                }
            } catch (error: Exception) {
                Log.e(TAG, "Bluetooth discovery failed; retry in 30 s (${error.javaClass.simpleName})")
                stopRadio(); retryAt = now() + 30_000
            }
            handler.postDelayed(this, 3_000)
        }
    }

    private fun startRadio() {
        if (mode == BluetoothDiscoveryMode.BROWSING) {
            startScanning()
            radioStarted = true
            Log.i(TAG, "Bluetooth room discovery scanning")
            return
        }
        server = manager.openGattServer(context, serverCallback)
            ?: throw IllegalStateException("Bluetooth GATT server unavailable")
        radioStarted = true
        val service = BluetoothGattService(SERVICE_ID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(RECORD_ID,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        if (Build.VERSION.SDK_INT >= 29) {
            // Own each allocation immediately so a later allocation failure closes all earlier PSMs.
            repeat(5) { sessionServers += requireNotNull(adapter).listenUsingInsecureL2capChannel() }
            localLanePSMs = BluetoothLanePSMs(sessionServers[0].psm, sessionServers[1].psm,
                sessionServers[2].psm, sessionServers[3].psm, metadata = sessionServers[4].psm)
            service.addCharacteristic(BluetoothGattCharacteristic(PSM_ID,
                BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
            service.addCharacteristic(BluetoothGattCharacteristic(LANE_PSMS_ID,
                BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
            for (listener in sessionServers) {
                io.execute {
                    while (true) {
                        try {
                            val socket = listener.accept()
                            handler.post {
                                if (sessionServers.none { it === listener }) socket.close()
                                else sessionBridge.accept(BluetoothByteConnection(socket)) {
                                    if (record.isEmpty()) null else BluetoothRoomRecord.decode(record)
                                }
                            }
                        } catch (error: Exception) {
                            handler.post {
                                if (sessionServers.any { it === listener }) {
                                    Log.e(TAG, "Bluetooth session accept failed; retry in 30 s (${error.javaClass.simpleName})")
                                    stopRadio(); retryAt = now() + 30_000
                                }
                            }
                            break
                        }
                    }
                }
            }
        }
        check(server?.addService(service) == true) { "Bluetooth service registration rejected" }
    }

    private fun stopRadio() {
        val listeners = sessionServers.toList(); sessionServers.clear(); localLanePSMs = null
        for (listener in listeners) {
            try { listener.close() }
            catch (error: Exception) { Log.w(TAG, "Bluetooth session listener close failed (${error.javaClass.simpleName})") }
        }
        sessionBridge.stop(); peerPSMs.clear(); roomEndpoints.clear()
        try { stopScanning() }
        catch (error: Exception) { Log.w(TAG, "Stop scan failed (${error.javaClass.simpleName})") }
        try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        catch (error: Exception) { Log.w(TAG, "Stop advertising failed (${error.javaClass.simpleName})") }
        links.keys.toList().forEach(::disconnect)
        try { server?.close() }
        catch (error: Exception) { Log.w(TAG, "Close server failed (${error.javaClass.simpleName})") }
        server = null; serviceReady = false; advertising = false; radioStarted = false
        rooms.values.forEach { onLost?.invoke(it.first.roomID) }
        rooms.clear(); attempts.clear(); snapshots.clear()
    }

    private fun disconnect(address: String) {
        rooms[address]?.first?.roomID?.let { roomEndpoints.remove(it) }
        peerPSMs.remove(address)
        val link = links.remove(address)
        characteristics.remove(address); pending.remove(address)
        try { link?.disconnect(); link?.close() }
        catch (error: Exception) { Log.w(TAG, "Close link failed (${error.javaClass.simpleName})") }
    }

    private fun updateAdvertising() {
        if (mode != BluetoothDiscoveryMode.ADVERTISING || !radioStarted || !serviceReady || now() < retryAt) return
        val advertiser = adapter?.bluetoothLeAdvertiser ?: run {
            retryAt = now() + 30_000
            Log.e(TAG, "Bluetooth advertising unavailable"); return
        }
        if (record.isEmpty()) {
            advertiser.stopAdvertising(advertiseCallback); advertising = false
        } else if (!advertising) {
            advertising = true
            advertiser.startAdvertising(AdvertiseSettings.Builder().setConnectable(true)
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE_ID)).build(), advertiseCallback)
        }
    }
    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settings: AdvertiseSettings) { Log.i(TAG, "Bluetooth room advertising started") }
        override fun onStartFailure(errorCode: Int) { handler.post {
            if (!running || mode != BluetoothDiscoveryMode.ADVERTISING) return@post
            retryAt = now() + 30_000
            advertising = false; Log.e(TAG, "Bluetooth advertising failed: $errorCode")
        } }
    }
    private val scanCallback = object : ScanCallback() {
        override fun onScanFailed(errorCode: Int) { handler.post {
            if (!running || mode != BluetoothDiscoveryMode.BROWSING) return@post
            Log.e(TAG, "Bluetooth scan failed: $errorCode; retry in 30 s")
            stopRadio(); retryAt = now() + 30_000
        } }
        override fun onScanResult(callbackType: Int, result: ScanResult) { handler.post {
            if (!running || mode != BluetoothDiscoveryMode.BROWSING || !radioStarted || !permitted()) return@post
            if (joinedRoom?.let { canConnect(it) } == true) return@post
            val address = result.device.address
            if (links.size >= 4 || links.containsKey(address) || now() - (attempts[address] ?: -6_000) < 6_000) return@post
            attempts[address] = now(); pending[address] = now()
            val link = result.device.connectGatt(context, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            if (link != null) links[address] = link else pending.remove(address)
        } }
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) { handler.post {
            if (!running || !radioStarted || !permitted()) return@post
            val address = gatt.device.address
            if (links[address] !== gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) disconnect(address)
            else if (newState == BluetoothProfile.STATE_CONNECTED && !gatt.discoverServices()) disconnect(address)
        } }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) { handler.post {
            if (!running || !radioStarted || !permitted()) return@post
            val address = gatt.device.address
            if (links[address] !== gatt) return@post
            val ch = gatt.getService(SERVICE_ID)?.getCharacteristic(RECORD_ID)
            if (status != BluetoothGatt.GATT_SUCCESS || ch == null) { disconnect(address); return@post }
            characteristics[address] = ch
            if (!gatt.readCharacteristic(ch)) disconnect(address)
        } }
        @Deprecated("Legacy Android callback")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT < 33) receive(gatt, characteristic.uuid, characteristic.value ?: byteArrayOf(), status)
        }
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            receive(gatt, characteristic.uuid, value.copyOf(), status)
        }
    }

    private fun receive(gatt: BluetoothGatt, characteristicID: UUID, value: ByteArray, status: Int) { handler.post {
        if (!running || !radioStarted || !permitted()) return@post
        val address = gatt.device.address
        if (links[address] !== gatt) return@post
        if (characteristicID == PSM_ID) {
            pending.remove(address)
            if (status == BluetoothGatt.GATT_SUCCESS && value.size == 2) {
                val psm = ((value[0].toInt() and 255) shl 8) or (value[1].toInt() and 255)
                if (psm > 0) peerPSMs[address] = psm
                else peerPSMs.remove(address)
                rooms[address]?.first?.let {
                    if (psm > 0) roomEndpoints[it.roomID] = Endpoint(gatt.device, psm)
                    else roomEndpoints.remove(it.roomID)
                    if (joinedRoom == it.roomID && psm > 0) {
                        stopScanning()
                        if (!gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH))
                            Log.w(TAG, "Bluetooth connection priority request rejected")
                    }
                    onRoom?.invoke(it)
                }
            }
            return@post
        }
        if (characteristicID != RECORD_ID) return@post
        pending.remove(address)
        if (status != BluetoothGatt.GATT_SUCCESS) {
            Log.e(TAG, "Bluetooth room read failed: $status"); disconnect(address); return@post
        }
        if (value.isEmpty()) {
            rooms.remove(address)?.let { onLost?.invoke(it.first.roomID) }
            disconnect(address); return@post
        }
        try {
            val decoded = BluetoothRoomRecord.decode(value)
            if (joinedRoom != null && decoded.roomID != joinedRoom) { disconnect(address); return@post }
            rooms[address]?.first?.takeIf { it.roomID != decoded.roomID }?.let { onLost?.invoke(it.roomID) }
            rooms[address] = decoded to now(); onRoom?.invoke(decoded)
            if (!peerPSMs.containsKey(address)) {
                gatt.getService(SERVICE_ID)?.getCharacteristic(PSM_ID)?.let { characteristic ->
                    pending[address] = now()
                    if (!gatt.readCharacteristic(characteristic)) pending.remove(address)
                }
            }
            Log.d(TAG, "Bluetooth room metadata received")
        } catch (error: Exception) {
            Log.e(TAG, "Invalid Bluetooth room record (${error.javaClass.simpleName})"); disconnect(address)
        }
    } }

    private fun startScanning() {
        if (scanning) return
        val scanner = adapter?.bluetoothLeScanner ?: error("Bluetooth scanner unavailable")
        scanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_ID)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCallback)
        scanning = true
    }
    private fun stopScanning() {
        if (!scanning) return
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        scanning = false
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) { handler.post {
            if (!running || mode != BluetoothDiscoveryMode.ADVERTISING || !radioStarted || !permitted()) return@post
            serviceReady = status == BluetoothGatt.GATT_SUCCESS
            if (serviceReady) updateAdvertising() else Log.e(TAG, "Bluetooth room service failed: $status")
        } }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int,
                                                 characteristic: BluetoothGattCharacteristic) { handler.post {
            if (!running || !radioStarted || !permitted()) return@post
            val current = server ?: return@post
            if (characteristic.uuid == PSM_ID || characteristic.uuid == LANE_PSMS_ID) {
                val endpoints = localLanePSMs
                if (endpoints == null) {
                    current.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null); return@post
                }
                // Legacy peers may still use admission's PSM for all GOD1 lanes.
                val bytes = if (characteristic.uuid == PSM_ID)
                    byteArrayOf((endpoints.admission shr 8).toByte(), endpoints.admission.toByte())
                else endpoints.encode()
                if (offset !in 0..bytes.size) current.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                else current.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes.copyOfRange(offset, bytes.size))
                return@post
            }
            if (characteristic.uuid != RECORD_ID) {
                current.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null); return@post
            }
            val address = device.address
            if (offset == 0) {
                snapshots.entries.removeAll { now() - it.value.second > 10_000 }
                if (!snapshots.containsKey(address) && snapshots.size >= 16) {
                    current.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null); return@post
                }
                snapshots[address] = record.copyOf() to now()
            }
            val bytes = snapshots[address]?.first
            if (bytes == null || offset !in 0..bytes.size) {
                current.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
            } else current.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes.copyOfRange(offset, bytes.size))
        } }
    }
}
