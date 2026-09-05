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
import com.aessam.toursession.BluetoothRoomRecord
import java.util.UUID

interface BluetoothRoomDiscoveryInterface {
    var onRoom: ((BluetoothRoomRecord) -> Unit)?
    var onLost: ((UUID) -> Unit)?
    fun start()
    fun stop()
    fun publish(record: BluetoothRoomRecord?)
}

/** Read-only room metadata. All mutable state is serialized on the main handler. */
@SuppressLint("MissingPermission") // Every radio start and refresh checks all runtime permissions.
class BluetoothRoomDiscovery(private val context: Context) : BluetoothRoomDiscoveryInterface {
    override var onRoom: ((BluetoothRoomRecord) -> Unit)? = null
    override var onLost: ((UUID) -> Unit)? = null
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var adapter: BluetoothAdapter? = null
    private var server: BluetoothGattServer? = null
    private var running = false
    private var radioStarted = false
    private var serviceReady = false
    private var advertising = false
    private var record = byteArrayOf()
    private val links = mutableMapOf<String, BluetoothGatt>()
    private val characteristics = mutableMapOf<String, BluetoothGattCharacteristic>()
    private val pending = mutableMapOf<String, Long>()
    private val attempts = mutableMapOf<String, Long>()
    private val rooms = mutableMapOf<String, Pair<BluetoothRoomRecord, Long>>()
    private val snapshots = mutableMapOf<String, Pair<ByteArray, Long>>()

    companion object {
        private const val TAG = "BluetoothRoomDiscovery"
        val SERVICE_ID: UUID = UUID.fromString("A1B2C3D4-0005-0000-0000-000000000000")
        val RECORD_ID: UUID = UUID.fromString("A1B2C3D4-0006-0000-0000-000000000000")
        fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
        ) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun permitted() = requiredPermissions().all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }
    private fun now() = SystemClock.elapsedRealtime()

    override fun start() {
        if (running) return
        running = true; handler.post(refresh)
    }
    override fun stop() {
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
                        if (!radioStarted) startRadio()
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
                Log.e(TAG, "Bluetooth discovery failed (${error.javaClass.simpleName})"); stopRadio()
            }
            handler.postDelayed(this, 3_000)
        }
    }

    private fun startRadio() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        server = manager.openGattServer(context, serverCallback)
            ?: throw IllegalStateException("Bluetooth GATT server unavailable")
        radioStarted = true
        val service = BluetoothGattService(SERVICE_ID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(RECORD_ID,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        check(server?.addService(service) == true) { "Bluetooth service registration rejected" }
        scanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_ID)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
        Log.i(TAG, "Bluetooth room discovery scanning")
    }

    private fun stopRadio() {
        try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
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
        val link = links.remove(address)
        characteristics.remove(address); pending.remove(address)
        try { link?.disconnect(); link?.close() }
        catch (error: Exception) { Log.w(TAG, "Close link failed (${error.javaClass.simpleName})") }
    }

    private fun updateAdvertising() {
        if (!radioStarted || !serviceReady) return
        val advertiser = adapter?.bluetoothLeAdvertiser ?: run {
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
            advertising = false; Log.e(TAG, "Bluetooth advertising failed: $errorCode")
        } }
    }
    private val scanCallback = object : ScanCallback() {
        override fun onScanFailed(errorCode: Int) { handler.post {
            Log.e(TAG, "Bluetooth scan failed: $errorCode"); stopRadio()
        } }
        override fun onScanResult(callbackType: Int, result: ScanResult) { handler.post {
            if (!running || !radioStarted || !permitted()) return@post
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
        if (links[address] !== gatt || characteristicID != RECORD_ID) return@post
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
            rooms[address]?.first?.takeIf { it.roomID != decoded.roomID }?.let { onLost?.invoke(it.roomID) }
            rooms[address] = decoded to now(); onRoom?.invoke(decoded)
            Log.d(TAG, "Bluetooth room metadata received")
        } catch (error: Exception) {
            Log.e(TAG, "Invalid Bluetooth room record (${error.javaClass.simpleName})"); disconnect(address)
        }
    } }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) { handler.post {
            if (!running || !radioStarted || !permitted()) return@post
            serviceReady = status == BluetoothGatt.GATT_SUCCESS
            if (serviceReady) updateAdvertising() else Log.e(TAG, "Bluetooth room service failed: $status")
        } }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int,
                                                 characteristic: BluetoothGattCharacteristic) { handler.post {
            if (!running || !radioStarted || !permitted()) return@post
            val current = server ?: return@post
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
