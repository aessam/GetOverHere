package com.aessam.comeoverhere.core

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.AwarePairingConfig
import android.net.wifi.aware.Characteristics
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.ServiceDiscoveryInfo
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareDataPathSecurityConfig
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.OsConstants
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.NearbyLaneRequest
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class NearbyAwarePeer(val id: String, val name: String)
data class NearbyAwareState(
    val enabled: Boolean = false,
    val hosting: Boolean = false,
    val pin: String = "",
    val peers: List<NearbyAwarePeer> = emptyList(),
    val error: String? = null,
)

interface NearbyAwareSettings {
    val state: StateFlow<NearbyAwareState>
    fun setEnabled(enabled: Boolean)
    fun pair(peerID: String, pin: String)
}

/** Native Aware discovery/pairing/NDP owner for the actual tour, not the UDP lab. */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
@SuppressLint("MissingPermission")
class WiFiAwareRoomTransport(
    context: Context,
    private val makePairingPIN: () -> String = { "%06d".format(SecureRandom().nextInt(1_000_000)) },
) {
    var onRoom: ((BluetoothRoomRecord) -> Unit)? = null
    var onLost: ((UUID) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    private val app = context.applicationContext
    private val manager = app.getSystemService(WifiAwareManager::class.java)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool { work -> Thread(work, "aware-room").apply { isDaemon = true } }
    private val bridge = NearbySocketBridge()
    private val mutableState = MutableStateFlow(NearbyAwareState())
    val state: StateFlow<NearbyAwareState> = mutableState.asStateFlow()
    @Volatile private var record: BluetoothRoomRecord? = null
    private var mode = BluetoothDiscoveryMode.OFF
    private var generation = 0L
    private var session: WifiAwareSession? = null
    private var discovery: DiscoverySession? = null
    private var server: ServerSocket? = null
    private var registered = false
    private var pairingSupported = false
    private val availability = NearbyAvailabilityTracker()
    private data class Candidate(
        val peer: PeerHandle,
        val id: String = UUID.randomUUID().toString(),
        var name: String = "Nearby device",
        var pin: String? = null,
        var route: Route? = null,
        var room: UUID? = null,
        var reading: Boolean = false,
        var supportsPairing: Boolean = false,
    )
    private data class Route(val network: Network, val address: Inet6Address, val port: Int)
    private val candidates = mutableMapOf<PeerHandle, Candidate>()
    private val callbacks = mutableMapOf<PeerHandle, ConnectivityManager.NetworkCallback>()
    private val roomRoutes = ConcurrentHashMap<UUID, Route>()
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val available = manager.isAvailable
            if (!availability.changed(available)) return
            val desired = mode
            if (desired != BluetoothDiscoveryMode.OFF) {
                val pin = mutableState.value.pin.takeIf { it.isNotEmpty() }
                stop()
                applyMode(desired, pin)
            }
        }
    }
    private val refresh = object : Runnable {
        override fun run() {
            if (mode != BluetoothDiscoveryMode.BROWSING) return
            candidates.values.toList().forEach { candidate -> candidate.route?.let { readRoom(candidate, it) } }
            handler.postDelayed(this, 5_000)
        }
    }

    fun publish(value: BluetoothRoomRecord?) { record = value }

    fun setMode(value: BluetoothDiscoveryMode) = applyMode(value, null)

    private fun applyMode(value: BluetoothDiscoveryMode, retainedPIN: String?) {
        if (mode == value) return
        stop()
        mode = value
        if (value == BluetoothDiscoveryMode.OFF) return
        val hosting = value == BluetoothDiscoveryMode.ADVERTISING
        mutableState.value = NearbyAwareState(enabled = true, hosting = hosting,
            pin = if (hosting) (retainedPIN ?: makePairingPIN()).also { require(it.length == 6 && it.all(Char::isDigit)) } else "")
        if (!app.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) {
            fail("Wi-Fi Aware is unsupported on this device"); return
        }
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
            fail("Nearby Wi-Fi permission is required"); return
        }
        app.registerReceiver(receiver, IntentFilter(WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED), Context.RECEIVER_NOT_EXPORTED)
        registered = true
        val available = manager.isAvailable
        availability.seed(available)
        if (!available) { fail("Wi-Fi Aware is unavailable. Keep Wi-Fi enabled; no router is needed."); return }
        pairingSupported = manager.characteristics?.isAwarePairingSupported == true
        val attempt = generation
        manager.attach(object : AttachCallback() {
            override fun onAttached(attached: WifiAwareSession) {
                if (generation != attempt) { attached.close(); return }
                session = attached
                try {
                    if (hosting) startServer(attempt)
                    val config = AwarePairingConfig.Builder().setPairingSetupEnabled(true)
                        .setPairingCacheEnabled(true).setPairingVerificationEnabled(true)
                        .setBootstrappingMethods(if (hosting) AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_DISPLAY
                            else AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD).build()
                    if (hosting) attached.publish(PublishConfig.Builder().setServiceName(SERVICE_NAME)
                        .setDataPathSecurityConfig(linkSecurity(mutableState.value.pin))
                        .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED).apply { if (pairingSupported) setPairingConfig(config) }.build(),
                        discoveryCallback(attempt, true), handler)
                    else attached.subscribe(SubscribeConfig.Builder().setServiceName(SERVICE_NAME)
                        .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE).apply { if (pairingSupported) setPairingConfig(config) }.build(),
                        discoveryCallback(attempt, false), handler)
                } catch (error: Exception) { fail("Aware startup failed (${error.javaClass.simpleName})") }
            }
            override fun onAttachFailed() { if (generation == attempt) fail("Wi-Fi Aware attach failed") }
        }, handler)
    }

    fun stop() {
        generation++
        mode = BluetoothDiscoveryMode.OFF
        handler.removeCallbacks(refresh)
        bridge.stop()
        try { server?.close() } catch (error: Exception) { Log.w(TAG, "Aware listener close failed (${error.javaClass.simpleName})") }
        server = null
        if (registered) { app.unregisterReceiver(receiver); registered = false }
        callbacks.values.forEach {
            try { connectivity.unregisterNetworkCallback(it) }
            catch (error: IllegalArgumentException) { Log.w(TAG, "Aware callback already removed (${error.javaClass.simpleName})") }
        }
        callbacks.clear()
        roomRoutes.clear()
        candidates.values.mapNotNull { it.room }.forEach { onLost?.invoke(it) }
        candidates.clear()
        discovery?.close(); discovery = null
        session?.close(); session = null
        mutableState.value = NearbyAwareState()
    }

    fun pair(id: String, pin: String) {
        if (pin.length !in 4..8 || pin.any { !it.isDigit() }) { fail("Enter the numeric device-pairing PIN shown by the guide"); return }
        val candidate = candidates.values.firstOrNull { it.id == id } ?: run { fail("Nearby device disappeared"); return }
        candidate.pin = pin
        try {
            if (pairingSupported && candidate.supportsPairing) initiatePairing(candidate)
            else {
                // Explicit Android legacy-NAN path: the NDP is authenticated by its PIN-derived
                // PSK. GOH room admission and payload authentication still run independently.
                discovery?.sendMessage(candidate.peer, 2, byteArrayOf(0x47, 0x4f, 0x44, 2))
            }
        }
        catch (error: Exception) { fail("Aware pairing could not start (${error.javaClass.simpleName})") }
    }

    /** Call from IO; the selected immutable route was resolved on the main thread. */
    fun connector(roomID: UUID): () -> NearbyByteConnection {
        check(roomRoutes.containsKey(roomID)) { "Aware room is no longer reachable" }
        return { open(requireNotNull(roomRoutes[roomID]) { "Aware route is reconnecting" }) }
    }

    private fun discoveryCallback(attempt: Long, hosting: Boolean) = object : DiscoverySessionCallback() {
        override fun onPublishStarted(value: PublishDiscoverySession) {
            if (generation != attempt) { value.close(); return }; discovery = value
        }
        override fun onSubscribeStarted(value: SubscribeDiscoverySession) {
            if (generation != attempt) { value.close(); return }; discovery = value
            handler.post(refresh)
        }
        override fun onServiceDiscovered(info: ServiceDiscoveryInfo) {
            if (generation != attempt || candidates.size >= 32 && !candidates.containsKey(info.peerHandle)) return
            val candidate = candidates.getOrPut(info.peerHandle) { Candidate(info.peerHandle) }
            candidate.supportsPairing = info.pairingConfig?.isPairingSetupEnabled == true
            updatePeers()
            discovery?.sendMessage(info.peerHandle, 1, byteArrayOf(0x47, 0x4f, 0x44, 1))
            // Device pairing does not expose its NDP key through the public Android API.
            // This Android-to-Android link requires the current displayed PIN as well.
            if (info.pairedAlias != null && candidate.pin != null) requestDataPath(candidate, hosting)
        }
        override fun onMessageReceived(peer: PeerHandle, message: ByteArray) {
            if (generation != attempt || candidates.size >= 32 && !candidates.containsKey(peer)) return
            val candidate = candidates.getOrPut(peer) { Candidate(peer) }; updatePeers()
            if (hosting && message.contentEquals(byteArrayOf(0x47, 0x4f, 0x44, 2))) {
                requestDataPath(candidate, hosting = true)
                // Publish the responder request before inviting the subscriber to initiate NDP.
                discovery?.sendMessage(peer, 3, byteArrayOf(0x47, 0x4f, 0x44, 3))
            } else if (!hosting && candidate.pin != null && message.contentEquals(byteArrayOf(0x47, 0x4f, 0x44, 3))) {
                requestDataPath(candidate, hosting = false)
            }
        }
        override fun onPairingSetupRequestReceived(peer: PeerHandle, requestID: Int) {
            if (generation != attempt) return
            if (candidates.size >= 32 && !candidates.containsKey(peer)) return
            val candidate = candidates.getOrPut(peer) { Candidate(peer) }
            val pin = if (hosting) mutableState.value.pin else candidate.pin
            if (pin.isNullOrEmpty()) { fail("Select the nearby guide and enter its device-pairing PIN"); return }
            discovery?.acceptPairingRequest(requestID, peer, "goh-${candidate.id}",
                Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128, pin)
        }
        override fun onBootstrappingSucceeded(peer: PeerHandle, method: Int) {
            if (generation == attempt) candidates[peer]?.let(::initiatePairing)
        }
        override fun onPairingSetupSucceeded(peer: PeerHandle, alias: String) {
            if (generation == attempt) candidates[peer]?.let { requestDataPath(it, hosting) }
        }
        override fun onPairingVerificationSucceed(peer: PeerHandle, alias: String) {
            if (generation != attempt) return
            if (candidates.size >= 32 && !candidates.containsKey(peer)) return
            requestDataPath(candidates.getOrPut(peer) { Candidate(peer) }, hosting)
        }
        override fun onPairingSetupFailed(peer: PeerHandle) { if (generation == attempt) fail("Aware pairing failed. Check the device PIN.") }
        override fun onBootstrappingFailed(peer: PeerHandle) { if (generation == attempt) fail("Aware bootstrapping failed") }
        override fun onPairingVerificationFailed(peer: PeerHandle) { if (generation == attempt) fail("Aware pairing verification failed") }
        override fun onSessionConfigFailed() { if (generation == attempt) fail("Aware discovery configuration failed") }
        override fun onSessionTerminated() { if (generation == attempt) { stop(); fail("Aware discovery terminated; enable it again to reconnect") } }
    }

    private fun initiatePairing(candidate: Candidate) {
        val pin = if (mode == BluetoothDiscoveryMode.ADVERTISING) mutableState.value.pin else candidate.pin
        if (pin.isNullOrEmpty()) { fail("Enter the guide's device-pairing PIN"); return }
        discovery?.initiatePairingRequest(candidate.peer, "goh-${candidate.id}",
            Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128, pin)
    }

    private fun startServer(attempt: Long) {
        val listener = ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(NearbyLaneRequest.SERVICE_PORT), 8) }
        server = listener
        io.execute {
            while (!listener.isClosed) {
                try {
                    val accepted = listener.accept()
                    handler.post {
                        if (generation != attempt) accepted.close()
                        else bridge.accept(NearbyTCPConnection(accepted)) { record }
                    }
                } catch (error: Exception) {
                    if (!listener.isClosed) handler.post { fail("Aware accept failed (${error.javaClass.simpleName})") }
                    break
                }
            }
        }
    }

    private fun requestDataPath(candidate: Candidate, hosting: Boolean) {
        if (callbacks.containsKey(candidate.peer)) return
        if ((manager.availableAwareResources?.availableDataPathsCount ?: 0) < 1) { fail("Aware capacity reached; existing guests were kept connected"); return }
        val active = discovery ?: return
        val attempt = generation
        val pin = if (hosting) mutableState.value.pin else candidate.pin
        if (pin.isNullOrEmpty()) { fail("Enter the current guide device PIN to connect the Aware data path"); return }
        val specifier = try {
            val security = linkSecurity(pin)
            WifiAwareNetworkSpecifier.Builder(active, candidate.peer).setDataPathSecurityConfig(security).apply {
                if (hosting) setPort(NearbyLaneRequest.SERVICE_PORT).setTransportProtocol(OsConstants.IPPROTO_TCP)
            }.build()
        } catch (error: Exception) {
            fail("Aware link configuration failed (${error.javaClass.simpleName})"); return
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (generation != attempt || hosting) return
                val info = capabilities.transportInfo as? WifiAwareNetworkInfo ?: return
                val address = info.peerIpv6Addr ?: return
                if (info.port <= 0) { fail("Aware guide did not advertise a tour endpoint"); return }
                val route = Route(network, address, info.port)
                candidate.route = route; readRoom(candidate, route)
            }
            override fun onLost(network: Network) {
                if (generation != attempt) return
                candidate.route = null
                candidate.room?.let { roomRoutes.remove(it); onLost?.invoke(it) }; candidate.room = null
                callbacks.remove(candidate.peer)?.let { connectivity.unregisterNetworkCallback(it) }
            }
            override fun onUnavailable() {
                if (generation == attempt) { callbacks.remove(candidate.peer); fail("Aware data path unavailable; retry pairing") }
            }
        }
        callbacks[candidate.peer] = callback
        try { connectivity.requestNetwork(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier).build(), callback, handler, 15_000) }
        catch (error: Exception) { callbacks.remove(candidate.peer); fail("Aware data path failed (${error.javaClass.simpleName})") }
    }

    private fun linkSecurity(pin: String): WifiAwareDataPathSecurityConfig =
        WifiAwareDataPathSecurityConfig.Builder(Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_SK_128)
            .setPskPassphrase("goh-device-$pin").build()


    private fun readRoom(candidate: Candidate, route: Route) {
        if (candidate.reading) return
        candidate.reading = true
        val attempt = generation
        io.execute {
            try {
                val found = bridge.readRecord { open(route) }
                handler.post {
                    if (generation == attempt && candidate.route == route) {
                        candidate.room?.takeIf { it != found.roomID }?.let { roomRoutes.remove(it); onLost?.invoke(it) }
                        roomRoutes[found.roomID] = route
                        candidate.room = found.roomID; candidate.name = found.name
                        onRoom?.invoke(found); updatePeers()
                    }
                    candidate.reading = false
                }
            } catch (error: Exception) {
                handler.post {
                    candidate.reading = false
                    if (generation == attempt) {
                        candidate.room?.let { roomRoutes.remove(it); onLost?.invoke(it) }; candidate.room = null
                        fail("Aware room metadata unavailable (${error.javaClass.simpleName})")
                    }
                }
            }
        }
    }

    private fun open(route: Route): NearbyByteConnection {
        val socket = route.network.socketFactory.createSocket()
        try { socket.connect(InetSocketAddress(route.address, route.port), 5_000); return NearbyTCPConnection(socket) }
        catch (error: Exception) { socket.close(); throw error }
    }
    private fun updatePeers() { mutableState.value = mutableState.value.copy(peers = candidates.values.map { NearbyAwarePeer(it.id, it.name) }) }
    private fun fail(message: String) {
        Log.w(TAG, message)
        mutableState.value = mutableState.value.copy(error = message)
        onError?.invoke(message)
    }
    companion object { const val SERVICE_NAME = "_goh-tour._tcp"; private const val TAG = "AwareRoom" }
}
