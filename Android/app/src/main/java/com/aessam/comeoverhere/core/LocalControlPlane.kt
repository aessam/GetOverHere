package com.aessam.comeoverhere.core

import android.annotation.SuppressLint
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.NetworkInterface
import java.util.UUID
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.SessionTransportRoute
import java.util.concurrent.ConcurrentHashMap

/**
 * NSD plus read-only Bluetooth room discovery. Only NSD supplies a join address.
 * Live channels publish `_goh-audio._tcp` and public Bluetooth GOR1 metadata.
 */
@SuppressLint("NewApi")
class LocalControlPlane(
    context: Context,
    displayName: String,
    bluetooth: BluetoothRoomDiscoveryInterface? = null,
    connectionBudget: NearbyConnectionBudget = NearbyConnectionBudget.sharedApp,
) : ControlPlane, NearbyRouteControl {
    private val bluetooth = bluetooth ?: BluetoothRoomDiscovery(context, connectionBudget)

    override val localPeer = PeerInfo(
        id = UUID.randomUUID().toString(),
        displayName = displayName,
        platform = PeerInfo.Platform.ANDROID
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val callbackExecutor = java.util.concurrent.Executor { command ->
        android.os.Handler(android.os.Looper.getMainLooper()).post(command)
    }
    private val serviceCallbacks = mutableMapOf<String, NsdManager.ServiceInfoCallback>()
    private val desiredAnnouncements = mutableMapOf<String, BLECommand.ChannelAnnounce>()
    private val updatingRegistrations = mutableSetOf<String>()
    private val legacyServices = mutableMapOf<String, NsdServiceInfo>()
    private val legacyHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var legacyResolveInFlight = false
    private var legacyResolveIndex = 0
    private val legacyRefresh = object : Runnable {
        override fun run() {
            val services = legacyServices.values.toList()
            if (!legacyResolveInFlight && services.isNotEmpty()) {
                legacyResolveInFlight = true
                val service = services[legacyResolveIndex++ % services.size]
                nsdManager.resolveService(service, resolveListener(service.serviceName))
            }
            legacyHandler.postDelayed(this, 2_000)
        }
    }

    private val _connectedPeers = MutableStateFlow<List<PeerInfo>>(emptyList())
    override val connectedPeers: StateFlow<List<PeerInfo>> = _connectedPeers.asStateFlow()

    private val _commands = MutableSharedFlow<Pair<BLECommand, PeerInfo>>(extraBufferCapacity = 64)
    override val commands: SharedFlow<Pair<BLECommand, PeerInfo>> = _commands.asSharedFlow()

    private val _peerEvents = MutableSharedFlow<PeerEvent>(extraBufferCapacity = 32)
    override val peerEvents: SharedFlow<PeerEvent> = _peerEvents.asSharedFlow()

    private val publishedServices = mutableMapOf<String, Pair<NsdServiceInfo, NsdManager.RegistrationListener>>()
    private val peerByChannelID = mutableMapOf<String, PeerInfo>()
    private var discoveryIndex = RoomDiscoveryIndex()
    private val aware = if (Build.VERSION.SDK_INT >= 34) WiFiAwareRoomTransport(context, connectionBudget) else null
    private var awareEnabled = false
    override var allowedTransportPolicy = com.aessam.toursession.AllowedTransportPolicy.AUTOMATIC
    private var hostedRecord: BluetoothRoomRecord? = null
    private val awareRooms = ConcurrentHashMap.newKeySet<UUID>()
    private val nearbyBridge = NearbySocketBridge(connectionBudget = connectionBudget)
    private val nearbyPreparation = Mutex()
    private val nearbyOwnerLock = Any()
    private var nearbyGeneration = 0L
    private var nearbyGuestConnector: (() -> NearbyByteConnection)? = null
    @Volatile override var activeNearbyGuestRoute: NearbyGuestRoute? = null
        private set
    override val usesBluetoothGuestRoute: Boolean
        get() = activeNearbyGuestRoute?.transport == SessionTransportRoute.BLUETOOTH
    override val awareSettings: NearbyAwareSettings? = aware?.let { transport ->
        object : NearbyAwareSettings {
            override val state = transport.state
            override val enabledPreference get() = awareEnabled
            override fun setEnabled(enabled: Boolean) {
                awareEnabled = enabled
                updateAwareMode()
            }
            override fun pair(peerID: String, pin: String) = transport.pair(peerID, pin)
        }
    }

    private fun updateAwareMode() {
        aware?.publish(hostedRecord)
        aware?.setMode(if (!awareEnabled) BluetoothDiscoveryMode.OFF
            else if (hostedRecord != null) BluetoothDiscoveryMode.ADVERTISING else BluetoothDiscoveryMode.BROWSING)
    }

    override fun canConnectNearby(roomID: UUID): Boolean =
        (roomID in awareRooms && allowedTransportPolicy.permits(SessionTransportRoute.WIFI_AWARE)) ||
        ((bluetooth as? BluetoothSessionDiscoveryInterface)?.canConnect(roomID) == true &&
            allowedTransportPolicy.permits(SessionTransportRoute.BLUETOOTH))
    override suspend fun prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID): NearbyGuestRoute = nearbyPreparation.withLock {
        withContext(Dispatchers.IO) {
            val cached = synchronized(nearbyOwnerLock) { activeNearbyGuestRoute?.let { it to nearbyGuestConnector } }
            if (cached != null) {
                check(allowedTransportPolicy.permits(cached.first.transport)) { "Active route is excluded by strict transport policy" }
                check(cached.first.roomID == roomID) { "Leave the current nearby room before joining another" }
                try {
                    val connect = requireNotNull(cached.second) { "Nearby adapter owner disappeared" }
                    NearbyRoomMetadataPolicy.validate(nearbyBridge.readRecord(connect), roomID, expectedGuideID)
                    synchronized(nearbyOwnerLock) {
                        check(activeNearbyGuestRoute?.routeID == cached.first.routeID) { "Nearby join was canceled" }
                        return@withContext cached.first
                    }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    Log.w(TAG, "Cached nearby route failed (${error.javaClass.simpleName})")
                    synchronized(nearbyOwnerLock) {
                        check(activeNearbyGuestRoute?.routeID == cached.first.routeID) { "Nearby join was canceled" }
                        stopNearbyGuest()
                    }
                    if (error is NearbyRoomMetadataMismatch) throw error
                }
            }
            val attempt = synchronized(nearbyOwnerLock) {
                check(activeNearbyGuestRoute == null) { "Nearby adapter changed during preparation" }
                nearbyGeneration
            }
            val bluetoothSession = bluetooth as? BluetoothSessionDiscoveryInterface
            val routes = buildList {
                if (roomID in awareRooms && allowedTransportPolicy.permits(SessionTransportRoute.WIFI_AWARE)) add(SessionTransportRoute.WIFI_AWARE)
                if (bluetoothSession?.canConnect(roomID) == true && allowedTransportPolicy.permits(SessionTransportRoute.BLUETOOTH)) add(SessionTransportRoute.BLUETOOTH)
            }
            check(routes.isNotEmpty()) { "No nearby route is available" }
            var lastError: Exception? = null
            for (route in routes) {
                try {
                    val connect = when (route) {
                        SessionTransportRoute.WIFI_AWARE -> requireNotNull(aware).connector(roomID)
                        SessionTransportRoute.BLUETOOTH -> requireNotNull(bluetoothSession).connector(roomID)
                        SessionTransportRoute.LOCAL_LAN, SessionTransportRoute.APPLE_PEER -> error("Unsupported Android nearby adapter route")
                    }
                    // Prove reachability before advertising a loopback adapter as connected. A stale
                    // preferred Aware endpoint may fail here and leave Bluetooth available to try.
                    NearbyRoomMetadataPolicy.validate(nearbyBridge.readRecord(connect), roomID, expectedGuideID)
                    return@withContext synchronized(nearbyOwnerLock) {
                        check(nearbyGeneration == attempt) { "Nearby join was canceled" }
                        if (route == SessionTransportRoute.BLUETOOTH) bluetoothSession?.setJoinedRoom(roomID)
                        val host = nearbyBridge.startGuest(roomID, connect)
                        NearbyGuestRoute(host, route, roomID, UUID.randomUUID()).also {
                            nearbyGuestConnector = connect
                            activeNearbyGuestRoute = it
                        }
                    }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    if (error is NearbyRoomMetadataMismatch) throw error
                    lastError = error
                    Log.w(TAG, "Nearby ${route.name} preparation failed (${error.javaClass.simpleName})")
                    synchronized(nearbyOwnerLock) {
                        check(nearbyGeneration == attempt) { "Nearby join was canceled" }
                        if (route == SessionTransportRoute.BLUETOOTH) bluetoothSession?.setJoinedRoom(null)
                    }
                }
            }
            throw IllegalStateException("No reachable nearby route could be prepared", lastError)
        }
    }
    override fun stopNearbyGuest() {
        synchronized(nearbyOwnerLock) {
            nearbyGeneration++
            nearbyBridge.stop()
            if (usesBluetoothGuestRoute) (bluetooth as? BluetoothSessionDiscoveryInterface)?.setJoinedRoom(null)
            activeNearbyGuestRoute = null
            nearbyGuestConnector = null
        }
    }

    init {
        aware?.onRoom = { record ->
            if (record.guideID != UUID.fromString(localPeer.id)) {
                awareRooms.add(record.roomID)
                val peer = PeerInfo(record.guideID.toString(), "Nearby guide",
                    if (record.isAndroid) PeerInfo.Platform.ANDROID else PeerInfo.Platform.IOS)
                emit(discoveryIndex.update(BLECommand.ChannelAnnounce(channelID = record.roomID.toString(),
                    channelName = record.name, createdBy = peer.id, audioQuality = AudioQuality.STANDARD,
                    wifiSSID = null, audioHostIP = null, roomAdmissionVersion = record.admissionVersion, isRoomLocked = record.isLocked),
                    peer, RoomDiscoveryIndex.Source.AWARE))
            }
        }
        aware?.onLost = { room ->
            awareRooms.remove(room)
            synchronized(nearbyOwnerLock) {
                if (activeNearbyGuestRoute?.let { it.roomID == room && it.transport == SessionTransportRoute.WIFI_AWARE } == true) {
                    stopNearbyGuest()
                }
            }
            emit(discoveryIndex.remove(room.toString(), RoomDiscoveryIndex.Source.AWARE))
        }
        this.bluetooth.onRoom = { record ->
            if (record.guideID != UUID.fromString(localPeer.id)) {
                val peer = PeerInfo(record.guideID.toString(), "Nearby guide",
                    if (record.isAndroid) PeerInfo.Platform.ANDROID else PeerInfo.Platform.IOS)
                emit(discoveryIndex.update(BLECommand.ChannelAnnounce(
                    channelID = record.roomID.toString(), channelName = record.name, createdBy = peer.id,
                    audioQuality = AudioQuality.STANDARD, wifiSSID = null, audioHostIP = null,
                    roomAdmissionVersion = record.admissionVersion, isRoomLocked = record.isLocked,
                ), peer, RoomDiscoveryIndex.Source.BLUETOOTH))
            }
        }
        this.bluetooth.onLost = { emit(discoveryIndex.remove(it.toString(), RoomDiscoveryIndex.Source.BLUETOOTH)) }
    }

    private fun emit(observation: Pair<BLECommand, PeerInfo>?) {
        if (observation == null) return
        _connectedPeers.value = discoveryIndex.peers
        if (!_commands.tryEmit(observation)) Log.e(TAG, "Room discovery event queue is full")
    }

    companion object {
        private const val TAG = "LocalControlPlane"
        private const val SERVICE_TYPE = "_goh-audio._tcp"
        private const val AUDIO_PORT = 50000
        private const val TXT_CHANNEL_NAME = "chname"
        private const val TXT_CREATED_BY = "createdBy"
        private const val TXT_CREATOR_NAME = "crname"
        private const val TXT_AUDIO_QUALITY = "quality"
        private const val TXT_PLATFORM = "platform"
    }

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Discovery failed: $errorCode")
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Discovery stop failed: $errorCode")
        }

        override fun onDiscoveryStarted(serviceType: String) {
            Log.i(TAG, "Local control plane started")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            Log.i(TAG, "Local control plane stopped")
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
                legacyHandler.post { onServiceFound(serviceInfo) }; return
            }
            if (normalizeServiceType(serviceInfo.serviceType) != normalizeServiceType(SERVICE_TYPE)) return
            if (publishedServices.containsKey(serviceInfo.serviceName)) return
            Log.i(TAG, "Found local service")
            if (Build.VERSION.SDK_INT >= 34) {
                if (serviceCallbacks.containsKey(serviceInfo.serviceName)) return
                val callback = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceUpdated(info: NsdServiceInfo) {
                        resolveListener(serviceInfo.serviceName).onServiceResolved(info)
                    }
                    override fun onServiceLost() = Unit // DiscoveryListener owns removal.
                    override fun onServiceInfoCallbackUnregistered() = Unit
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                        serviceCallbacks.remove(serviceInfo.serviceName)
                        Log.e(TAG, "Service monitoring failed: $errorCode")
                    }
                }
                serviceCallbacks[serviceInfo.serviceName] = callback
                nsdManager.registerServiceInfoCallback(serviceInfo, callbackExecutor, callback)
            } else {
                legacyServices[serviceInfo.serviceName] = serviceInfo
            }
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
                legacyHandler.post { onServiceLost(serviceInfo) }; return
            }
            legacyServices.remove(serviceInfo.serviceName)
            if (Build.VERSION.SDK_INT >= 34) {
                serviceCallbacks.remove(serviceInfo.serviceName)?.let(nsdManager::unregisterServiceInfoCallback)
            }
            val peer = peerByChannelID.remove(serviceInfo.serviceName) ?: return
            emit(discoveryIndex.remove(serviceInfo.serviceName, RoomDiscoveryIndex.Source.LAN))
            if (_connectedPeers.value.none { it.id == peer.id }) _peerEvents.tryEmit(PeerEvent.Disconnected(peer))
        }
    }

    override fun start() {
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        if (Build.VERSION.SDK_INT < 34) legacyHandler.post(legacyRefresh)
    }

    override fun setBluetoothDiscoveryMode(mode: BluetoothDiscoveryMode) = bluetooth.setMode(mode)

    override fun stop() {
        stopNearbyGuest()
        aware?.stop()
        bluetooth.stop()
        discoveryIndex = RoomDiscoveryIndex()
        legacyHandler.removeCallbacks(legacyRefresh)
        legacyServices.clear()
        legacyResolveInFlight = false
        desiredAnnouncements.clear()
        updatingRegistrations.clear()
        if (Build.VERSION.SDK_INT >= 34) serviceCallbacks.values.forEach(nsdManager::unregisterServiceInfoCallback)
        serviceCallbacks.clear()
        try {
            nsdManager.stopServiceDiscovery(discoveryListener)
        } catch (error: Exception) {
                Log.w(TAG, "Failed to stop local service discovery (${error.javaClass.simpleName})")
        }
        publishedServices.values.forEach { (_, listener) ->
            try {
                nsdManager.unregisterService(listener)
            } catch (error: Exception) {
                Log.w(TAG, "Failed to unregister local service (${error.javaClass.simpleName})")
            }
        }
        publishedServices.clear()
        peerByChannelID.clear()
        _connectedPeers.value = emptyList()
    }

    override fun broadcast(command: BLECommand) {
        when (command) {
            is BLECommand.ChannelAnnounce -> publishChannel(command)
            is BLECommand.ChannelEnded -> unpublishChannel(command.channelID)
            else -> Unit
        }
    }

    override fun send(command: BLECommand, to: PeerInfo) {
        broadcast(command)
    }

    private fun publishChannel(announce: BLECommand.ChannelAnnounce) {
        val record = BluetoothRoomRecord(UUID.fromString(announce.channelID), UUID.fromString(announce.createdBy),
            announce.channelName, true, announce.isRoomLocked ?: true, admissionVersion = announce.roomAdmissionVersion ?: 1)
        hostedRecord = record
        bluetooth.publish(record)
        updateAwareMode()
        desiredAnnouncements[announce.channelID] = announce
        if (updatingRegistrations.contains(announce.channelID)) return
        publishedServices[announce.channelID]?.let { (info, listener) ->
            val lock = if (announce.isRoomLocked == false) "0" else "1"
            if (info.attributes["locked"]?.decodeToString() == lock) return
            updatingRegistrations.add(announce.channelID)
            try {
                nsdManager.unregisterService(listener)
            } catch (error: Exception) {
                updatingRegistrations.remove(announce.channelID)
                Log.e(TAG, "Cannot update room discovery (${error.javaClass.simpleName})")
            }
            return
        }

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = announce.channelID
            serviceType = SERVICE_TYPE
            port = AUDIO_PORT
            setAttribute(TXT_CHANNEL_NAME, announce.channelName)
            setAttribute(TXT_CREATED_BY, announce.createdBy)
            setAttribute(TXT_CREATOR_NAME, localPeer.displayName)
            setAttribute(TXT_AUDIO_QUALITY, announce.audioQuality.rawValue)
            setAttribute(TXT_PLATFORM, localPeer.platform.rawValue)
            setAttribute("admission", (announce.roomAdmissionVersion ?: 0).toString())
            setAttribute("locked", if (announce.isRoomLocked == false) "0" else "1")
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "Published local channel")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                publishedServices.remove(announce.channelID)
                Log.e(TAG, "Register failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                if (updatingRegistrations.remove(announce.channelID)) {
                    publishedServices.remove(announce.channelID)
                    desiredAnnouncements[announce.channelID]?.let(::publishChannel)
                }
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                updatingRegistrations.remove(announce.channelID)
                Log.e(TAG, "Unregister failed: $errorCode")
            }
        }

        publishedServices[announce.channelID] = serviceInfo to listener
        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun unpublishChannel(channelID: String) {
        bluetooth.publish(null)
        hostedRecord = null
        updateAwareMode()
        desiredAnnouncements.remove(channelID)
        if (updatingRegistrations.contains(channelID)) return
        val (_, listener) = publishedServices.remove(channelID) ?: return
        try {
            nsdManager.unregisterService(listener)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to unpublish channel (${error.javaClass.simpleName})")
        }
    }

    private fun resolveListener(channelID: String) = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            legacyResolveInFlight = false
            Log.e(TAG, "Resolve failed: $errorCode")
        }

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
                legacyHandler.post { onServiceResolved(serviceInfo) }; return
            }
            legacyResolveInFlight = false
            val createdBy = serviceInfo.attributes[TXT_CREATED_BY]?.decodeToString() ?: return
            if (createdBy == localPeer.id) return
            val creatorName = serviceInfo.attributes[TXT_CREATOR_NAME]?.decodeToString() ?: "Peer"
            val channelName = serviceInfo.attributes[TXT_CHANNEL_NAME]?.decodeToString() ?: serviceInfo.serviceName
            val quality = serviceInfo.attributes[TXT_AUDIO_QUALITY]?.decodeToString()?.let(AudioQuality::fromRaw) ?: AudioQuality.STANDARD
            val platform = serviceInfo.attributes[TXT_PLATFORM]?.decodeToString()?.let(PeerInfo.Platform::fromRaw) ?: PeerInfo.Platform.ANDROID
            val hostIP = if (Build.VERSION.SDK_INT >= 34) {
                serviceInfo.hostAddresses.firstOrNull { it is java.net.Inet4Address }?.hostAddress
            } else serviceInfo.host?.hostAddress
            Log.i(TAG, "Resolved local channel")

            val peer = PeerInfo(id = createdBy, displayName = creatorName, platform = platform)
            peerByChannelID[channelID] = peer
            if (_connectedPeers.value.none { it.id == peer.id }) {
                _connectedPeers.value = _connectedPeers.value + peer
                _peerEvents.tryEmit(PeerEvent.Connected(peer))
            }

            emit(discoveryIndex.update(
                BLECommand.ChannelAnnounce(
                    channelID = serviceInfo.serviceName,
                    channelName = channelName,
                    createdBy = createdBy,
                    audioQuality = quality,
                    wifiSSID = null,
                    audioHostIP = hostIP,
                    roomAdmissionVersion = serviceInfo.attributes["admission"]?.decodeToString()?.toIntOrNull(),
                    isRoomLocked = serviceInfo.attributes["locked"]?.decodeToString() != "0",
                ), peer, RoomDiscoveryIndex.Source.LAN
            ))
        }
    }

    private fun normalizeServiceType(type: String?): String = type?.trimEnd('.') ?: ""
}
