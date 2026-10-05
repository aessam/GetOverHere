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
import android.net.LinkProperties
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

data class NearbyAwarePeer(val id: String, val name: String,
    val profile: NearbyAwareProfile = NearbyAwareProfile.ANDROID_PSK) {
    val requiresPIN: Boolean get() = profile.requiresPIN
}
data class NearbyAwareState(
    val enabled: Boolean = false,
    val hosting: Boolean = false,
    val pin: String = "",
    val peers: List<NearbyAwarePeer> = emptyList(),
    val error: String? = null,
    val profiles: Set<NearbyAwareProfile> = emptySet(),
    val systemPairingUnavailableReason: String? = null,
    val diagnostics: NearbyAwareDiagnostics = NearbyAwareDiagnostics(),
)

interface NearbyAwareSettings {
    val state: StateFlow<NearbyAwareState>
    /** User/owner preference, independent of a radio start failure. */
    val enabledPreference: Boolean get() = state.value.enabled
    fun setEnabled(enabled: Boolean)
    fun pair(peerID: String, pin: String)
}

/** Native Aware discovery/pairing/NDP owner for the actual tour, not the UDP lab. */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
@SuppressLint("MissingPermission")
private class WiFiAwareProfileOwner(
    context: Context,
    private val profile: NearbyAwareProfile,
    connectionBudget: NearbyConnectionBudget,
    private val pathReservations: AwarePathReservations,
    private val makePairingPIN: () -> String = { "%06d".format(SecureRandom().nextInt(1_000_000)) },
    private val guideLaneConnector: GuideLaneConnector? = null,
) {
    var onRoom: ((BluetoothRoomRecord) -> Unit)? = null
    var onLost: ((UUID) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onState: (() -> Unit)? = null
    private val app = context.applicationContext
    private val manager = app.getSystemService(WifiAwareManager::class.java)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool { work -> Thread(work, "aware-room").apply { isDaemon = true } }
    private val bridge = NearbySocketBridge(connectionBudget = connectionBudget,
        guideLaneConnector = guideLaneConnector,
        audioResidenceMilliseconds = if (guideLaneConnector == null) com.aessam.toursession.NearbyRealtimeQueue.LIFETIME_MILLISECONDS
            else com.aessam.toursession.GatewayProtocol.AUDIO_RESIDENCE_MILLISECONDS)
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
    private val pathLeases = mutableMapOf<PeerHandle, AwarePathReservations.Lease>()
    private val networkDiagnostics = mutableMapOf<PeerHandle, AwareNetworkDiagnostic>()
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
        updateState(NearbyAwareState(enabled = true, hosting = hosting,
            profiles = setOf(profile),
            pin = if (hosting && profile.requiresPIN) (retainedPIN ?: makePairingPIN()).also {
                require(it.length == 6 && it.all(Char::isDigit))
            } else ""))
        if (hosting && profile == NearbyAwareProfile.SYSTEM_PAIRED) {
            terminateDiscovery("System-paired publishing needs a public endpoint bootstrap; no dummy link key was installed")
            return
        }
        if (!app.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) {
            fail("Wi-Fi Aware is unsupported on this device"); return
        }
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
            fail("Nearby Wi-Fi permission is required"); return
        }
        try {
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
                    Log.d(TAG, "Aware attached; hosting=$hosting")
                    try {
                        if (hosting) startServer(attempt)
                        val config = AwarePairingConfig.Builder().setPairingSetupEnabled(true)
                            .setPairingCacheEnabled(true).setPairingVerificationEnabled(true)
                            .setBootstrappingMethods(if (hosting) AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_DISPLAY
                                else AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD).build()
                        if (hosting) attached.publish(PublishConfig.Builder().setServiceName(profile.serviceName)
                            .setDataPathSecurityConfig(linkSecurity(mutableState.value.pin))
                            .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED).apply { if (pairingSupported) setPairingConfig(config) }.build(),
                            discoveryCallback(attempt, true), handler)
                        else attached.subscribe(SubscribeConfig.Builder().setServiceName(profile.serviceName)
                            .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE).apply {
                                if (profile == NearbyAwareProfile.SYSTEM_PAIRED) enableSystemPairing(this)
                                else if (pairingSupported) setPairingConfig(config)
                            }.build(),
                            discoveryCallback(attempt, false), handler)
                    } catch (error: Exception) { terminateDiscovery("Aware startup failed (${error.javaClass.simpleName})") }
                }
                override fun onAttachFailed() { if (generation == attempt) terminateDiscovery("Wi-Fi Aware attach failed") }
            }, handler)
        } catch (error: Exception) {
            // Permission/radio state can change between capability checks and synchronous attach.
            terminateDiscovery("Aware attach could not start (${error.javaClass.simpleName})")
        }
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
        pathLeases.values.forEach { it.close() }; pathLeases.clear()
        networkDiagnostics.clear()
        roomRoutes.clear()
        candidates.values.mapNotNull { it.room }.forEach { onLost?.invoke(it) }
        candidates.clear()
        discovery?.close(); discovery = null
        session?.close(); session = null
        updateState(NearbyAwareState())
    }

    fun pair(id: String, pin: String) {
        val candidate = candidates.values.firstOrNull { it.id == id } ?: run { fail("Nearby device disappeared"); return }
        if (profile == NearbyAwareProfile.SYSTEM_PAIRED) {
            if (pin.isNotEmpty()) { fail("Complete this device's pairing in the system dialog, not the Android PIN field"); return }
            requestDataPath(candidate, hosting = false)
            return
        }
        if (pin.length !in 4..8 || pin.any { !it.isDigit() }) { fail("Enter the numeric device-pairing PIN shown by the guide"); return }
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
        val route = requireNotNull(roomRoutes[roomID]) { "Aware room is no longer reachable" }
        return { open(route) }
    }

    private fun discoveryCallback(attempt: Long, hosting: Boolean) = object : DiscoverySessionCallback() {
        override fun onPublishStarted(value: PublishDiscoverySession) {
            if (generation != attempt) { value.close(); return }; discovery = value
            Log.d(TAG, "Aware publish ready")
        }
        override fun onSubscribeStarted(value: SubscribeDiscoverySession) {
            if (generation != attempt) { value.close(); return }; discovery = value
            Log.d(TAG, "Aware subscribe ready")
            handler.post(refresh)
        }
        override fun onServiceDiscovered(info: ServiceDiscoveryInfo) {
            if (generation != attempt || candidates.size >= 32 && !candidates.containsKey(info.peerHandle)) return
            Log.d(TAG, "Aware peer discovered")
            val candidate = candidates.getOrPut(info.peerHandle) { Candidate(info.peerHandle) }
            candidate.supportsPairing = info.pairingConfig?.isPairingSetupEnabled == true
            updatePeers()
            // Discovery alone must never trigger an OS consent/PIN dialog for an unselected peer.
            if (profile == NearbyAwareProfile.SYSTEM_PAIRED) return
            discovery?.sendMessage(info.peerHandle, 1, byteArrayOf(0x47, 0x4f, 0x44, 1))
            // Device pairing does not expose its NDP key through the public Android API.
            // This Android-to-Android link requires the current displayed PIN as well.
            if (info.pairedAlias != null && candidate.pin != null) requestDataPath(candidate, hosting)
        }
        override fun onMessageReceived(peer: PeerHandle, message: ByteArray) {
            if (profile == NearbyAwareProfile.SYSTEM_PAIRED) return
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
            if (profile == NearbyAwareProfile.SYSTEM_PAIRED) return
            if (generation != attempt) return
            if (candidates.size >= 32 && !candidates.containsKey(peer)) return
            val candidate = candidates.getOrPut(peer) { Candidate(peer) }
            val pin = if (hosting) mutableState.value.pin else candidate.pin
            if (pin.isNullOrEmpty()) { fail("Select the nearby guide and enter its device-pairing PIN"); return }
            discovery?.acceptPairingRequest(requestID, peer, "goh-${candidate.id}",
                Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128, pin)
        }
        override fun onBootstrappingSucceeded(peer: PeerHandle, method: Int) {
            if (profile == NearbyAwareProfile.SYSTEM_PAIRED) return
            if (generation == attempt) candidates[peer]?.let(::initiatePairing)
        }
        override fun onPairingSetupSucceeded(peer: PeerHandle, alias: String) {
            if (profile == NearbyAwareProfile.SYSTEM_PAIRED) return
            if (generation == attempt) candidates[peer]?.let { requestDataPath(it, hosting) }
        }
        override fun onPairingVerificationSucceed(peer: PeerHandle, alias: String) {
            if (profile == NearbyAwareProfile.SYSTEM_PAIRED) return
            if (generation != attempt) return
            if (candidates.size >= 32 && !candidates.containsKey(peer)) return
            requestDataPath(candidates.getOrPut(peer) { Candidate(peer) }, hosting)
        }
        override fun onPairingSetupFailed(peer: PeerHandle) { if (generation == attempt) fail("Aware pairing failed. Check the device PIN.") }
        override fun onBootstrappingFailed(peer: PeerHandle) { if (generation == attempt) fail("Aware bootstrapping failed") }
        override fun onPairingVerificationFailed(peer: PeerHandle) { if (generation == attempt) fail("Aware pairing verification failed") }
        override fun onSessionConfigFailed() { if (generation == attempt) terminateDiscovery("Aware discovery configuration failed") }
        override fun onSessionTerminated() { if (generation == attempt) terminateDiscovery("Aware discovery terminated; enable it again to reconnect") }
    }

    private fun initiatePairing(candidate: Candidate) {
        val pin = if (mode == BluetoothDiscoveryMode.ADVERTISING) mutableState.value.pin else candidate.pin
        if (pin.isNullOrEmpty()) { fail("Enter the guide's device-pairing PIN"); return }
        discovery?.initiatePairingRequest(candidate.peer, "goh-${candidate.id}",
            Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128, pin)
    }

    private fun startServer(attempt: Long) {
        val listener = openListener()
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
        val active = discovery ?: return
        val attempt = generation
        val pin = if (hosting) mutableState.value.pin else candidate.pin
        if (profile.requiresPIN && pin.isNullOrEmpty()) { fail("Enter the current guide device PIN to connect the Aware data path"); return }
        val reservation = try {
            pathReservations.reserve(manager.characteristics?.numberOfSupportedDataPaths,
                manager.availableAwareResources?.availableDataPathsCount)
        } catch (error: Exception) { fail(error.message ?: "Aware path resources unavailable"); return }
        val specifier = try {
            WifiAwareNetworkSpecifier.Builder(active, candidate.peer).apply {
                if (profile.requiresPIN) setDataPathSecurityConfig(linkSecurity(requireNotNull(pin)))
                if (hosting) {
                    check(profile == NearbyAwareProfile.ANDROID_PSK) { "System publisher endpoint bootstrap is not available" }
                    val listener = requireNotNull(server) { "Aware listener is unavailable" }
                    check(!listener.isClosed)
                    setPort(listener.localPort).setTransportProtocol(OsConstants.IPPROTO_TCP)
                }
            }.build()
        } catch (error: Exception) {
            reservation.close()
            fail("Aware link configuration failed (${error.javaClass.simpleName})"); return
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (generation != attempt || callbacks[candidate.peer] !== this) return
                reservation.established(network.networkHandle)
                networkDiagnostics[candidate.peer] = AwareNetworkDiagnostic(profile, network.networkHandle, null)
                updateDiagnostics()
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if (generation != attempt || callbacks[candidate.peer] !== this) return
                networkDiagnostics[candidate.peer] = AwareNetworkDiagnostic(profile, network.networkHandle, properties.interfaceName)
                updateDiagnostics()
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (generation != attempt || callbacks[candidate.peer] !== this || hosting) return
                val info = capabilities.transportInfo as? WifiAwareNetworkInfo ?: return
                val address = info.peerIpv6Addr ?: return
                if (info.port <= 0) {
                    callbacks.remove(candidate.peer)
                    connectivity.unregisterNetworkCallback(this)
                    pathLeases.remove(candidate.peer)?.close()
                    networkDiagnostics.remove(candidate.peer)
                    updateDiagnostics()
                    fail("Aware guide did not advertise a tour endpoint")
                    return
                }
                Log.d(TAG, "Aware data path ready")
                val route = Route(network, address, info.port)
                candidate.route = route
                updateState(mutableState.value.copy(error = null))
                readRoom(candidate, route)
            }
            override fun onLost(network: Network) {
                if (generation != attempt || callbacks[candidate.peer] !== this) return
                val lostRoute = candidate.route
                candidate.route = null
                candidate.room?.let { room -> lostRoute?.let { removeRoomRoute(room, it) } }
                candidate.room = null
                callbacks.remove(candidate.peer)?.let { connectivity.unregisterNetworkCallback(it) }
                pathLeases.remove(candidate.peer)?.close()
                networkDiagnostics.remove(candidate.peer)
                updateDiagnostics()
            }
            override fun onUnavailable() {
                if (generation == attempt && callbacks[candidate.peer] === this) {
                    callbacks.remove(candidate.peer)
                    pathLeases.remove(candidate.peer)?.close()
                    networkDiagnostics.remove(candidate.peer)
                    updateDiagnostics()
                    fail("Aware ${profile.name} data path unavailable; retry the selected peer")
                }
            }
        }
        callbacks[candidate.peer] = callback
        pathLeases[candidate.peer] = reservation
        updateDiagnostics()
        try { connectivity.requestNetwork(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier).build(), callback, handler, profile.requestTimeoutMilliseconds) }
        catch (error: Exception) {
            callbacks.remove(candidate.peer)
            pathLeases.remove(candidate.peer)?.close()
            updateDiagnostics()
            fail("Aware data path failed (${error.javaClass.simpleName})")
        }
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
                        candidate.room?.takeIf { it != found.roomID }?.let { removeRoomRoute(it, route) }
                        roomRoutes[found.roomID] = route
                        candidate.room = found.roomID; candidate.name = found.name
                        onRoom?.invoke(found); updatePeers()
                    }
                    candidate.reading = false
                }
            } catch (error: Exception) {
                handler.post {
                    candidate.reading = false
                    if (generation == attempt && candidate.route == route) {
                        candidate.room?.let { removeRoomRoute(it, route) }; candidate.room = null
                        fail("Aware room metadata unavailable (${error.javaClass.simpleName})")
                    }
                }
            }
        }
    }

    private fun removeRoomRoute(roomID: UUID, expectedRoute: Route) {
        // Another candidate/profile may already have supplied a replacement for the same room.
        if (roomRoutes.remove(roomID, expectedRoute)) onLost?.invoke(roomID)
    }

    private fun open(route: Route): NearbyByteConnection {
        val socket = route.network.socketFactory.createSocket()
        try { socket.connect(InetSocketAddress(route.address, route.port), 5_000); return NearbyTCPConnection(socket) }
        catch (error: Exception) { socket.close(); throw error }
    }
    private fun updatePeers() { updateState(mutableState.value.copy(peers = candidates.values.map { NearbyAwarePeer(it.id, it.name, profile) })) }
    private fun updateState(value: NearbyAwareState) { mutableState.value = value; onState?.invoke() }
    private fun updateDiagnostics() {
        try {
            val characteristics = manager.characteristics
            updateState(mutableState.value.copy(diagnostics = NearbyAwareDiagnostics(
                sdkInt = Build.VERSION.SDK_INT, sdkIntFull = sdkIntFull(), pairingSupported = pairingSupported,
                offloadMethods = offloadMethods(characteristics), maximumDataPaths = characteristics?.numberOfSupportedDataPaths,
                availableDataPaths = manager.availableAwareResources?.availableDataPathsCount,
                pendingDataPaths = pathReservations.snapshot().pending, networks = networkDiagnostics.values.toList(),
            )))
        } catch (error: Exception) { fail("Aware resource diagnostics failed (${error.javaClass.simpleName})") }
    }
    private fun terminateDiscovery(message: String) {
        // A dead native owner must not retain its listener, routes, or an enabled UI switch.
        // Per-peer failures still use fail() and leave other guests connected.
        stop()
        fail(message)
    }
    private fun fail(message: String) {
        Log.w(TAG, message)
        updateState(mutableState.value.copy(error = message))
        onError?.invoke(message)
    }
    companion object {
        private const val TAG = "AwareRoom"

        fun sdkIntFull(): Int? = if (Build.VERSION.SDK_INT >= 36) Build.VERSION.SDK_INT_FULL else null

        @SuppressLint("NewApi")
        fun offloadMethods(characteristics: Characteristics?): Int =
            if ((sdkIntFull() ?: 0) >= Build.VERSION_CODES_FULL.CINNAMON_BUN_2) {
                characteristics?.supportedOffloadBootstrappingMethods ?: 0
            } else 0

        @SuppressLint("NewApi")
        private fun enableSystemPairing(builder: SubscribeConfig.Builder) {
            check((sdkIntFull() ?: 0) >= Build.VERSION_CODES_FULL.CINNAMON_BUN_2)
            builder.setFrameworkOffloadedPairingEnabled(true)
        }

        internal fun openListener(): ServerSocket {
            val listener = ServerSocket()
            try {
                listener.reuseAddress = true
                // Fixed 50004 can already be an unrelated outgoing connection's local port.
                // The NDP advertises the assigned port; guests already consume that metadata.
                listener.bind(InetSocketAddress(0), 8)
                return listener
            } catch (error: Exception) { listener.close(); throw error }
        }
    }
}

/** Explicit profile owners keep Android PIN compatibility separate from the public 37.2 system
 * pairing candidate. A failure in one profile cannot close connections belonging to another.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
@SuppressLint("MissingPermission")
class WiFiAwareRoomTransport(
    context: Context,
    private val connectionBudget: NearbyConnectionBudget = NearbyConnectionBudget.sharedApp,
    private val guideLaneConnector: GuideLaneConnector? = null,
    private val makePairingPIN: () -> String = { "%06d".format(SecureRandom().nextInt(1_000_000)) },
) {
    var onRoom: ((BluetoothRoomRecord) -> Unit)? = null
    var onLost: ((UUID) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    private val app = context.applicationContext
    private val manager = app.getSystemService(WifiAwareManager::class.java)
    private val reservations = AwarePathReservations()
    private val owners = mutableMapOf<NearbyAwareProfile, WiFiAwareProfileOwner>()
    private val records = mutableMapOf<UUID, MutableMap<NearbyAwareProfile, BluetoothRoomRecord>>()
    private val selectedOwners = ConcurrentHashMap<UUID, WiFiAwareProfileOwner>()
    private val mutableState = MutableStateFlow(NearbyAwareState())
    val state: StateFlow<NearbyAwareState> = mutableState.asStateFlow()
    private var currentRecord: BluetoothRoomRecord? = null
    private var mode = BluetoothDiscoveryMode.OFF
    private var plan = AwareProfilePlan(emptySet(), null)

    fun publish(value: BluetoothRoomRecord?) {
        currentRecord = value
        owners.values.forEach { it.publish(value) }
    }

    fun setMode(value: BluetoothDiscoveryMode) {
        if (mode == value && (value == BluetoothDiscoveryMode.OFF || owners.values.any { it.state.value.enabled })) return
        stop()
        mode = value
        if (value == BluetoothDiscoveryMode.OFF) return
        val hosting = value == BluetoothDiscoveryMode.ADVERTISING
        try {
            val characteristics = manager?.characteristics
            val resources = manager?.availableAwareResources
            plan = AwareProfilePolicy.plan(hosting, Build.VERSION.SDK_INT, WiFiAwareProfileOwner.sdkIntFull(),
                characteristics?.isAwarePairingSupported == true, WiFiAwareProfileOwner.offloadMethods(characteristics),
                if (hosting) resources?.availablePublishSessionsCount else resources?.availableSubscribeSessionsCount)
        } catch (error: Exception) {
            plan = AwareProfilePlan(setOf(NearbyAwareProfile.ANDROID_PSK),
                "System pairing capabilities unavailable (${error.javaClass.simpleName}); Android PIN profile retained")
            Log.w("AwareRoom", requireNotNull(plan.systemUnavailableReason))
        }
        plan.profiles.forEach { profile ->
            val owner = owners.getOrPut(profile) {
                WiFiAwareProfileOwner(app, profile, connectionBudget, reservations, makePairingPIN, guideLaneConnector).also { child ->
                    child.onState = { updateState() }
                    child.onRoom = { record ->
                        records.getOrPut(record.roomID) { mutableMapOf() }[profile] = record
                        selectedOwners.putIfAbsent(record.roomID, child)
                        if (selectedOwners[record.roomID] === child) onRoom?.invoke(record)
                    }
                    child.onLost = { room ->
                        val remaining = records[room]
                        remaining?.remove(profile)
                        if (selectedOwners[room] === child) {
                            selectedOwners.remove(room)
                            val alternate = remaining?.keys?.minByOrNull { it.ordinal }
                            val alternateOwner = alternate?.let(owners::get)
                            if (alternate != null && alternateOwner != null) {
                                selectedOwners[room] = alternateOwner
                                remaining[alternate]?.let { onRoom?.invoke(it) }
                            } else onLost?.invoke(room)
                        }
                        if (remaining.isNullOrEmpty()) records.remove(room)
                    }
                    child.onError = { message -> onError?.invoke("${profile.name}: $message") }
                }
            }
            owner.publish(currentRecord)
            owner.setMode(value)
        }
        updateState()
    }

    fun pair(id: String, pin: String) {
        val owner = owners.values.firstOrNull { child -> child.state.value.peers.any { it.id == id } }
        if (owner == null) {
            mutableState.value = mutableState.value.copy(error = "Nearby device disappeared")
            onError?.invoke("Nearby device disappeared")
        } else owner.pair(id, pin)
    }

    fun connector(roomID: UUID): () -> NearbyByteConnection =
        requireNotNull(selectedOwners[roomID]) { "Aware room is no longer reachable" }.connector(roomID)

    fun stop() {
        mode = BluetoothDiscoveryMode.OFF
        owners.values.forEach { it.stop() }
        selectedOwners.clear()
        records.clear()
        plan = AwareProfilePlan(emptySet(), null)
        mutableState.value = NearbyAwareState()
    }

    private fun updateState() {
        val childStates = owners.values.map { it.state.value }
        val enabled = childStates.filter { it.enabled }
        val diagnostic = childStates.firstOrNull { it.diagnostics.sdkInt > 0 }?.diagnostics ?: NearbyAwareDiagnostics()
        mutableState.value = NearbyAwareState(enabled = enabled.isNotEmpty(), hosting = mode == BluetoothDiscoveryMode.ADVERTISING,
            pin = owners[NearbyAwareProfile.ANDROID_PSK]?.state?.value?.pin.orEmpty(),
            peers = enabled.flatMap { it.peers }, error = childStates.mapNotNull { it.error }.lastOrNull(),
            profiles = enabled.flatMap { it.profiles }.toSet(), systemPairingUnavailableReason = plan.systemUnavailableReason,
            diagnostics = diagnostic.copy(pendingDataPaths = reservations.snapshot().pending,
                networks = childStates.flatMap { it.diagnostics.networks }.distinctBy { it.networkHandle }),
        )
    }

    companion object {
        const val SERVICE_NAME = "_goh-andr._tcp"
        internal fun openListener(): ServerSocket = WiFiAwareProfileOwner.openListener()
    }
}
