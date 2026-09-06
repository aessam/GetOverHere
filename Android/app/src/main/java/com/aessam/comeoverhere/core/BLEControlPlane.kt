package com.aessam.comeoverhere.core

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import kotlinx.coroutines.flow.*
import java.util.UUID

/**
 * BLE GATT control plane. Handles discovery, commands, and coordination.
 * NO audio — only lightweight JSON BLECommands over GATT.
 *
 * Each device is both peripheral (GATT server + advertiser) and central (scanner + GATT client).
 * Commands flow bidirectionally:
 * - Central writes → remote peripheral's COMMAND_WRITE characteristic
 * - Peripheral notifies → remote central via COMMAND_NOTIFY characteristic
 *
 * Peer info exchange: "id|displayName|platform" on the PEER_INFO characteristic (read-only).
 *
 * Permissions (BLUETOOTH_ADVERTISE, BLUETOOTH_CONNECT, BLUETOOTH_SCAN) are requested in
 * MainActivity before start() is called. Lint suppression is used here since the permission
 * check happens at the call site.
 */
@SuppressLint("MissingPermission")
class BLEControlPlane(
    private val context: Context,
    displayName: String
) : ControlPlane {
    override fun setBluetoothDiscoveryMode(mode: BluetoothDiscoveryMode) {
        check(mode == BluetoothDiscoveryMode.OFF) { "Legacy BLE control is not room discovery" }
    }

    override val localPeer = PeerInfo(
        id = UUID.randomUUID().toString(),
        displayName = displayName,
        platform = PeerInfo.Platform.ANDROID
    )

    private val _connectedPeers = MutableStateFlow<List<PeerInfo>>(emptyList())
    override val connectedPeers: StateFlow<List<PeerInfo>> = _connectedPeers.asStateFlow()

    private val _commands = MutableSharedFlow<Pair<BLECommand, PeerInfo>>(extraBufferCapacity = 64)
    override val commands: SharedFlow<Pair<BLECommand, PeerInfo>> = _commands.asSharedFlow()

    private val _peerEvents = MutableSharedFlow<PeerEvent>(extraBufferCapacity = 32)
    override val peerEvents: SharedFlow<PeerEvent> = _peerEvents.asSharedFlow()

    // BLE infrastructure
    private val bluetoothManager by lazy {
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }
    private val bluetoothAdapter: BluetoothAdapter? by lazy { bluetoothManager.adapter }

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var commandNotifyChar: BluetoothGattCharacteristic? = null

    // Peer tracking (bleID = device address or UUID string)
    private val connectedGattClients: MutableMap<String, BluetoothDevice> = mutableMapOf() // address → device
    private val peerByAddress: MutableMap<String, PeerInfo> = mutableMapOf()
    private val gattConnections: MutableMap<String, BluetoothGatt> = mutableMapOf() // address → gatt
    private val writeCharByAddress: MutableMap<String, BluetoothGattCharacteristic> = mutableMapOf()

    companion object {
        private const val TAG = "BLEControlPlane"
    }

    private val peerInfoData: ByteArray
        get() = "${localPeer.id}|${localPeer.displayName}|${localPeer.platform.rawValue}"
            .toByteArray(Charsets.UTF_8)

    private fun parsePeerInfo(data: ByteArray): PeerInfo? {
        val str = String(data, Charsets.UTF_8)
        val parts = str.split("|", limit = 3)
        if (parts.size != 3) return null
        return PeerInfo(
            id = parts[0],
            displayName = parts[1],
            platform = PeerInfo.Platform.fromRaw(parts[2])
        )
    }

    private fun registerPeer(peer: PeerInfo, address: String) {
        if (peer.id == localPeer.id) return
        peerByAddress[address] = peer
        if (_connectedPeers.value.none { it.id == peer.id }) {
            _connectedPeers.value = _connectedPeers.value + peer
            _peerEvents.tryEmit(PeerEvent.Connected(peer))
            Log.i(TAG, "BLE peer connected (${peer.platform.rawValue})")
        }
    }

    // MARK: - Lifecycle

    override fun start() {
        setupGattServer()
        startAdvertising()
        startScanning()
        Log.i(TAG, "BLE control plane starting")
    }

    override fun stop() {
        scanner?.stopScan(scanCallback)
        advertiser?.stopAdvertising(advertiseCallback)
        gattConnections.values.forEach { it.disconnect(); it.close() }
        gattServer?.close()
        gattServer = null
        gattConnections.clear()
        writeCharByAddress.clear()
        peerByAddress.clear()
        connectedGattClients.clear()
        _connectedPeers.value = emptyList()
        Log.i(TAG, "BLE control plane stopped")
    }

    // MARK: - GATT Server

    private fun setupGattServer() {
        gattServer = bluetoothManager.openGattServer(context, gattServerCallback)

        val writeCh = BluetoothGattCharacteristic(
            BLEConstants.COMMAND_WRITE_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        val notifyCh = BluetoothGattCharacteristic(
            BLEConstants.COMMAND_NOTIFY_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        ).also { ch ->
            ch.addDescriptor(
                BluetoothGattDescriptor(BLEConstants.CCCD_UUID, BluetoothGattDescriptor.PERMISSION_WRITE or BluetoothGattDescriptor.PERMISSION_READ)
            )
        }
        commandNotifyChar = notifyCh

        val peerInfoCh = BluetoothGattCharacteristic(
            BLEConstants.PEER_INFO_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        ).also { it.value = peerInfoData }

        val service = BluetoothGattService(BLEConstants.SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(writeCh)
        service.addCharacteristic(notifyCh)
        service.addCharacteristic(peerInfoCh)
        gattServer?.addService(service)
        Log.i(TAG, "GATT server set up")
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedGattClients[device.address] = device
                Log.i(TAG, "GATT client connected")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedGattClients.remove(device.address)
                val peer = peerByAddress.remove(device.address)
                if (peer != null) {
                    _connectedPeers.value = _connectedPeers.value.filter { it.id != peer.id }
                    _peerEvents.tryEmit(PeerEvent.Disconnected(peer))
                }
                Log.i(TAG, "GATT client disconnected")
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (characteristic.uuid == BLEConstants.COMMAND_WRITE_UUID) {
                val peer = peerByAddress[device.address]
                    ?: PeerInfo(id = device.address, displayName = "BLE-${device.address.takeLast(5)}")
                if (peerByAddress[device.address] == null) {
                    peerByAddress[device.address] = peer
                    registerPeer(peer, device.address)
                }
                val cmd = parseBLECommand(value)
                if (cmd != null) {
                    _commands.tryEmit(cmd to peer)
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == BLEConstants.PEER_INFO_UUID) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, peerInfoData)
            } else {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    // MARK: - Advertising

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "BLE advertising started")
        }
        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "BLE advertising failed: $errorCode")
        }
    }

    private fun startAdvertising() {
        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(BLEConstants.SERVICE_UUID))
            .setIncludeDeviceName(false)
            .build()
        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    // MARK: - Scanning

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val address = device.address
            if (gattConnections.containsKey(address)) return

            val serviceUUIDs = result.scanRecord?.serviceUuids ?: return
            if (!serviceUUIDs.contains(ParcelUuid(BLEConstants.SERVICE_UUID))) return

            Log.i(TAG, "Discovered BLE peer; connecting")
            connectToPeripheral(device)
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "BLE scan failed: $errorCode")
        }
    }

    private fun startScanning() {
        scanner = bluetoothAdapter?.bluetoothLeScanner
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(BLEConstants.SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner?.startScan(listOf(filter), settings, scanCallback)
        Log.i(TAG, "BLE scanning started")
    }

    // MARK: - GATT Client

    private fun connectToPeripheral(device: BluetoothDevice) {
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattClientCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, gattClientCallback)
        }
        gattConnections[device.address] = gatt
    }

    private val gattClientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.i(TAG, "GATT connected; requesting MTU")
                gatt.requestMtu(512) // discoverServices called in onMtuChanged
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val peer = peerByAddress.remove(address)
                if (peer != null) {
                    _connectedPeers.value = _connectedPeers.value.filter { it.id != peer.id }
                    _peerEvents.tryEmit(PeerEvent.Disconnected(peer))
                }
                gattConnections.remove(address)
                writeCharByAddress.remove(address)
                gatt.close()
                Log.i(TAG, "GATT disconnected; will rescan")
                // Auto-reconnect via scanner picking it up again
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            Log.i(TAG, "MTU negotiated: $mtu")
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val address = gatt.device.address
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed: $status")
                return
            }
            val service = gatt.getService(BLEConstants.SERVICE_UUID) ?: run {
                Log.e(TAG, "Service not found")
                return
            }

            // Wire up write characteristic
            service.getCharacteristic(BLEConstants.COMMAND_WRITE_UUID)?.let { ch ->
                writeCharByAddress[address] = ch
            }

            // Subscribe to notify characteristic
            service.getCharacteristic(BLEConstants.COMMAND_NOTIFY_UUID)?.let { ch ->
                gatt.setCharacteristicNotification(ch, true)
                ch.getDescriptor(BLEConstants.CCCD_UUID)?.let { desc ->
                    desc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(desc)
                }
            }

            // Peer info read happens in onDescriptorWrite callback after CCCD write completes
            // (GATT operations must be sequential — can't read while write is pending)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int
        ) {
            // CCCD write done — now safe to read peer info
            val service = gatt.getService(BLEConstants.SERVICE_UUID) ?: return
            service.getCharacteristic(BLEConstants.PEER_INFO_UUID)?.let { ch ->
                gatt.readCharacteristic(ch)
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            val address = gatt.device.address
            if (characteristic.uuid == BLEConstants.PEER_INFO_UUID) {
                val peer = parsePeerInfo(characteristic.value ?: return) ?: return
                registerPeer(peer, address)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic
        ) {
            val address = gatt.device.address
            if (characteristic.uuid == BLEConstants.COMMAND_NOTIFY_UUID) {
                val peer = peerByAddress[address] ?: return
                val cmd = parseBLECommand(characteristic.value ?: return) ?: return
                _commands.tryEmit(cmd to peer)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "BLE write failed: $status")
            }
        }
    }

    // MARK: - Send Commands

    override fun broadcast(command: BLECommand) {
        val data = command.toJson()

        // Write to all connected peripheral GATT connections (central role)
        for ((address, gatt) in gattConnections) {
            writeCharByAddress[address]?.let { ch ->
                ch.value = data
                gatt.writeCharacteristic(ch)
            }
        }

        // Notify all subscribed centrals (peripheral role)
        commandNotifyChar?.let { ch ->
            ch.value = data
            connectedGattClients.values.forEach { device ->
                gattServer?.notifyCharacteristicChanged(device, ch, false)
            }
        }
    }

    override fun send(command: BLECommand, to: PeerInfo) {
        val data = command.toJson()
        val address = peerByAddress.entries.find { it.value.id == to.id }?.key ?: return

        // Try central write
        gattConnections[address]?.let { gatt ->
            writeCharByAddress[address]?.let { ch ->
                ch.value = data
                gatt.writeCharacteristic(ch)
                return
            }
        }

        // Fall back to notify if device is a GATT client on our server
        commandNotifyChar?.let { ch ->
            ch.value = data
            connectedGattClients[address]?.let { device ->
                gattServer?.notifyCharacteristicChanged(device, ch, false)
            }
        }
    }
}
