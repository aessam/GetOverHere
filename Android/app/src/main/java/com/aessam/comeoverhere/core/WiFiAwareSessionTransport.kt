package com.aessam.comeoverhere.core

import android.content.Context
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
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.OsConstants
import android.util.Log
import com.aessam.toursession.AwareSessionAnnouncement
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Production Wi-Fi Aware discovery and NAN data-path owner.
 *
 * The guide publishes GOHA session metadata and keeps the existing authenticated
 * lane servers on ports 50000-50002. A guest receives one [GuestRoute], then all
 * three lane sockets are created by that route's [Network.socketFactory].
 */
class WiFiAwareSessionTransport(
    context: Context,
) : AutoCloseable {
    enum class Mode { STOPPED, BROWSING, HOSTING }

    data class Snapshot(
        val supported: Boolean,
        val available: Boolean,
        val mode: Mode = Mode.STOPPED,
        val discoveredSessionCount: Int = 0,
        val connectedDataPathCount: Int = 0,
        val lastError: String? = null,
    )

    data class GuestRoute(
        val announcement: AwareSessionAnnouncement,
        val network: Network,
        val guideAddress: Inet6Address,
    ) {
        val guideHost: String
            get() = requireNotNull(guideAddress.hostAddress) { "Aware guide address is unavailable" }
    }

    private data class Candidate(
        val peer: PeerHandle,
        val discoverySession: DiscoverySession,
        var announcement: AwareSessionAnnouncement?,
        var pairedAlias: String?,
        var route: GuestRoute? = null,
    )

    private val appContext = context.applicationContext
    private val awareManager = appContext.getSystemService(WifiAwareManager::class.java)
    private val connectivityManager = appContext.getSystemService(ConnectivityManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool { body ->
        Thread(body, "aware-production-io").apply { isDaemon = true }
    }
    private val candidatesByPeer = ConcurrentHashMap<PeerHandle, Candidate>()
    private val candidatesBySession = ConcurrentHashMap<UUID, Candidate>()
    private val callbacksByPeer = ConcurrentHashMap<PeerHandle, ConnectivityManager.NetworkCallback>()
    private val pendingConnects = ConcurrentHashMap<UUID, MutableList<(Result<GuestRoute>) -> Unit>>()
    private val activeNetworks = ConcurrentHashMap<PeerHandle, Network>()

    private val initialSupported = isHardwareSupported()
    private val mutableSnapshot = MutableStateFlow(
        Snapshot(
            supported = initialSupported,
            available = initialSupported && awareManager.isAvailable,
        ),
    )
    val snapshot: StateFlow<Snapshot> = mutableSnapshot.asStateFlow()

    private val mutableAnnouncements = MutableSharedFlow<AwareSessionAnnouncement>(extraBufferCapacity = 16)
    val announcements: SharedFlow<AwareSessionAnnouncement> = mutableAnnouncements.asSharedFlow()

    private var awareSession: WifiAwareSession? = null
    private var isAttaching = false
    private var discoverySession: DiscoverySession? = null
    private var hostedAnnouncement: AwareSessionAnnouncement? = null
    private var bootstrapServer: ServerSocket? = null

    fun start() {
        if (!isHardwareSupported()) {
            fail("Wi-Fi Aware is unsupported on this Android device")
            return
        }
        if (!awareManager.isAvailable) {
            fail("Wi-Fi Aware is currently unavailable; keep Wi-Fi enabled")
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            awareManager.characteristics?.isAwarePairingSupported != true
        ) {
            fail("Cross-platform Wi-Fi Aware requires Android 14 pairing support")
            return
        }
        if (awareSession != null || isAttaching) return

        try {
            isAttaching = true
            awareManager.attach(object : AttachCallback() {
                override fun onAttached(session: WifiAwareSession) {
                    isAttaching = false
                    awareSession = session
                    val announcement = hostedAnnouncement
                    if (announcement == null) {
                        startBrowsing(session)
                    } else {
                        startHosting(session, announcement)
                    }
                }

                override fun onAttachFailed() {
                    isAttaching = false
                    fail("Wi-Fi Aware attach failed")
                }
            }, mainHandler)
        } catch (error: SecurityException) {
            isAttaching = false
            fail("Nearby Wi-Fi permission is required")
        } catch (error: RuntimeException) {
            isAttaching = false
            fail("Wi-Fi Aware attach failed (${error.javaClass.simpleName})")
        }
    }

    fun host(announcement: AwareSessionAnnouncement) {
        hostedAnnouncement = announcement
        val session = awareSession ?: run {
            start()
            return
        }
        startHosting(session, announcement)
    }

    private fun startHosting(session: WifiAwareSession, announcement: AwareSessionAnnouncement) {
        discoverySession?.close()
        discoverySession = null
        candidatesByPeer.clear()
        candidatesBySession.clear()
        closeNetworkCallbacks()
        startBootstrapServer(announcement)

        val config = PublishConfig.Builder()
            .setServiceName(SERVICE_NAME)
            .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED)
            .setServiceSpecificInfo(announcement.encode())
            .setPairingConfig(pairingConfig(isPublisher = true))
            .build()
        session.publish(config, discoveryCallback(isPublisher = true), mainHandler)
    }

    fun stopHosting() {
        hostedAnnouncement = null
        bootstrapServer.closeQuietly()
        bootstrapServer = null
        discoverySession?.close()
        discoverySession = null
        closeNetworkCallbacks()
        awareSession?.let(::startBrowsing)
    }

    fun connect(sessionID: UUID, completion: (Result<GuestRoute>) -> Unit) {
        val candidate = candidatesBySession[sessionID]
        if (candidate == null) {
            completion(Result.failure(IllegalStateException("Wi-Fi Aware guide is no longer discoverable")))
            return
        }
        candidate.route?.let {
            completion(Result.success(it))
            return
        }
        if (candidate.pairedAlias == null) {
            completion(
                Result.failure(
                    IllegalStateException("Pair this guide once in the Wi-Fi Aware screen before joining offline"),
                ),
            )
            return
        }
        pendingConnects.compute(sessionID) { _, callbacks ->
            (callbacks ?: mutableListOf()).apply { add(completion) }
        }
        requestDataPath(candidate, isPublisher = false)
    }

    override fun close() {
        hostedAnnouncement = null
        bootstrapServer.closeQuietly()
        bootstrapServer = null
        discoverySession?.close()
        discoverySession = null
        closeNetworkCallbacks()
        awareSession?.close()
        awareSession = null
        isAttaching = false
        candidatesByPeer.clear()
        candidatesBySession.clear()
        pendingConnects.clear()
        mutableSnapshot.value = mutableSnapshot.value.copy(
            mode = Mode.STOPPED,
            discoveredSessionCount = 0,
            connectedDataPathCount = 0,
        )
        ioExecutor.shutdownNow()
    }

    private fun startBrowsing(session: WifiAwareSession) {
        if (hostedAnnouncement != null) return
        val config = SubscribeConfig.Builder()
            .setServiceName(SERVICE_NAME)
            .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE)
            .setPairingConfig(pairingConfig(isPublisher = false))
            .build()
        session.subscribe(config, discoveryCallback(isPublisher = false), mainHandler)
    }

    private fun discoveryCallback(isPublisher: Boolean) = object : DiscoverySessionCallback() {
        override fun onPublishStarted(session: PublishDiscoverySession) {
            discoverySession = session
            mutableSnapshot.value = mutableSnapshot.value.copy(
                available = true,
                mode = Mode.HOSTING,
                lastError = null,
            )
            Log.i(TAG, "Production Wi-Fi Aware guide advertising")
        }

        override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
            discoverySession = session
            mutableSnapshot.value = mutableSnapshot.value.copy(
                available = true,
                mode = Mode.BROWSING,
                lastError = null,
            )
            Log.i(TAG, "Production Wi-Fi Aware guest browsing")
        }

        override fun onSessionConfigFailed() {
            fail("Wi-Fi Aware discovery configuration failed")
        }

        override fun onSessionTerminated() {
            discoverySession = null
            if (awareSession != null) fail("Wi-Fi Aware discovery session terminated")
        }

        override fun onServiceDiscovered(info: ServiceDiscoveryInfo) {
            val activeDiscovery = discoverySession ?: return
            val announcement = info.serviceSpecificInfo?.let { bytes ->
                runCatching { AwareSessionAnnouncement.decode(bytes) }.getOrNull()
            }
            val candidate = candidatesByPeer.compute(info.peerHandle) { _, existing ->
                (existing ?: Candidate(info.peerHandle, activeDiscovery, announcement, info.pairedAlias)).also {
                    if (announcement != null) it.announcement = announcement
                    it.pairedAlias = info.pairedAlias
                }
            } ?: return
            announcement?.let(::publishAnnouncement)

            if (isPublisher) {
                if (candidate.pairedAlias != null) {
                    requestDataPath(candidate, isPublisher = true)
                } else {
                    Log.i(TAG, "Aware peer discovered but is not paired")
                }
            } else if (announcement == null && candidate.pairedAlias != null) {
                // Apple does not expose Android-style service-specific info. Open
                // one bootstrap connection to obtain the same GOHA announcement.
                requestDataPath(candidate, isPublisher = false)
            }
        }

        override fun onPairingVerificationSucceed(peerHandle: PeerHandle, alias: String) {
            val candidate = candidatesByPeer[peerHandle] ?: return
            candidate.pairedAlias = alias
            if (isPublisher) requestDataPath(candidate, isPublisher = true)
        }

        override fun onPairingVerificationFailed(peerHandle: PeerHandle) {
            failPending(peerHandle, "Wi-Fi Aware pairing verification failed")
        }
    }

    private fun requestDataPath(candidate: Candidate, isPublisher: Boolean) {
        if (callbacksByPeer.containsKey(candidate.peer)) return
        val builder = WifiAwareNetworkSpecifier.Builder(candidate.discoverySession, candidate.peer)
        if (isPublisher) {
            builder.setPort(BOOTSTRAP_PORT).setTransportProtocol(OsConstants.IPPROTO_TCP)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(builder.build())
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                activeNetworks[candidate.peer] = network
                updateDataPathCount()
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val info = capabilities.transportInfo as? WifiAwareNetworkInfo ?: return
                val peerAddress = info.peerIpv6Addr ?: return
                activeNetworks[candidate.peer] = network
                updateDataPathCount()
                if (!isPublisher) {
                    completeGuestRoute(candidate, network, peerAddress, info.port)
                }
            }

            override fun onLost(network: Network) {
                activeNetworks.remove(candidate.peer)
                candidate.route = null
                updateDataPathCount()
            }

            override fun onUnavailable() {
                callbacksByPeer.remove(candidate.peer)
                failPending(candidate.peer, "Wi-Fi Aware data path is unavailable")
            }
        }
        callbacksByPeer[candidate.peer] = callback
        try {
            connectivityManager.requestNetwork(request, callback, mainHandler)
        } catch (error: SecurityException) {
            callbacksByPeer.remove(candidate.peer)
            failPending(candidate.peer, "Nearby Wi-Fi permission is required")
        } catch (error: RuntimeException) {
            callbacksByPeer.remove(candidate.peer)
            failPending(candidate.peer, "Wi-Fi Aware data path failed (${error.javaClass.simpleName})")
        }
    }

    private fun completeGuestRoute(
        candidate: Candidate,
        network: Network,
        peerAddress: Inet6Address,
        advertisedPort: Int,
    ) {
        val existingAnnouncement = candidate.announcement
        if (existingAnnouncement != null) {
            finishGuestRoute(candidate, existingAnnouncement, network, peerAddress)
            return
        }
        if (advertisedPort <= 0) {
            failPending(candidate.peer, "Aware guide did not advertise a bootstrap port")
            return
        }
        ioExecutor.execute {
            try {
                val announcement = readBootstrap(network, peerAddress, advertisedPort)
                mainHandler.post {
                    candidate.announcement = announcement
                    publishAnnouncement(announcement)
                    finishGuestRoute(candidate, announcement, network, peerAddress)
                }
            } catch (error: Exception) {
                mainHandler.post {
                    failPending(candidate.peer, "Aware bootstrap failed (${error.javaClass.simpleName})")
                }
            }
        }
    }

    private fun finishGuestRoute(
        candidate: Candidate,
        announcement: AwareSessionAnnouncement,
        network: Network,
        peerAddress: Inet6Address,
    ) {
        val route = GuestRoute(announcement, network, peerAddress)
        candidate.route = route
        candidatesBySession[announcement.sessionID] = candidate
        pendingConnects.remove(announcement.sessionID)?.forEach { it(Result.success(route)) }
    }

    private fun publishAnnouncement(announcement: AwareSessionAnnouncement) {
        candidatesByPeer.values.firstOrNull { it.announcement?.sessionID == announcement.sessionID }?.let {
            candidatesBySession[announcement.sessionID] = it
        }
        mutableAnnouncements.tryEmit(announcement)
        mutableSnapshot.value = mutableSnapshot.value.copy(
            discoveredSessionCount = candidatesBySession.size,
            lastError = null,
        )
    }

    private fun startBootstrapServer(announcement: AwareSessionAnnouncement) {
        bootstrapServer.closeQuietly()
        val server = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(BOOTSTRAP_PORT), 16)
            }
        } catch (error: Exception) {
            fail("Aware bootstrap server failed (${error.javaClass.simpleName})")
            return
        }
        bootstrapServer = server
        ioExecutor.execute {
            while (!server.isClosed && hostedAnnouncement?.sessionID == announcement.sessionID) {
                val socket = try {
                    server.accept()
                } catch (error: Exception) {
                    if (!server.isClosed) fail("Aware bootstrap accept failed (${error.javaClass.simpleName})")
                    break
                }
                ioExecutor.execute { writeBootstrap(socket, announcement) }
            }
        }
    }

    private fun writeBootstrap(socket: Socket, announcement: AwareSessionAnnouncement) {
        socket.use { connected ->
            val bytes = announcement.encode()
            DataOutputStream(connected.getOutputStream()).use { output ->
                output.writeInt(bytes.size)
                output.write(bytes)
                output.flush()
            }
        }
    }

    private fun readBootstrap(network: Network, address: Inet6Address, port: Int): AwareSessionAnnouncement {
        val socket = network.socketFactory.createSocket()
        socket.use { connected ->
            connected.connect(InetSocketAddress(address, port), CONNECT_TIMEOUT_MILLISECONDS)
            connected.soTimeout = CONNECT_TIMEOUT_MILLISECONDS
            val input = DataInputStream(connected.getInputStream())
            val length = input.readInt()
            require(length in 1..MAXIMUM_BOOTSTRAP_SIZE) { "invalid Aware bootstrap length $length" }
            return AwareSessionAnnouncement.decode(ByteArray(length).also(input::readFully))
        }
    }

    private fun failPending(peer: PeerHandle, message: String) {
        val candidate = candidatesByPeer[peer]
        candidate?.announcement?.sessionID?.let { sessionID ->
            pendingConnects.remove(sessionID)?.forEach {
                it(Result.failure(IllegalStateException(message)))
            }
        }
        mutableSnapshot.value = mutableSnapshot.value.copy(lastError = message)
        Log.e(TAG, message)
    }

    private fun fail(message: String) {
        mutableSnapshot.value = mutableSnapshot.value.copy(
            available = isHardwareSupported() && awareManager.isAvailable,
            lastError = message,
        )
        Log.e(TAG, message)
    }

    private fun updateDataPathCount() {
        mutableSnapshot.value = mutableSnapshot.value.copy(connectedDataPathCount = activeNetworks.size)
    }

    private fun closeNetworkCallbacks() {
        callbacksByPeer.values.toList().forEach { callback ->
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "Aware network callback was already removed")
            }
        }
        callbacksByPeer.clear()
        activeNetworks.clear()
        updateDataPathCount()
    }

    private fun pairingConfig(isPublisher: Boolean): AwarePairingConfig {
        val method = if (isPublisher) {
            AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_DISPLAY
        } else {
            AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD
        }
        return AwarePairingConfig.Builder()
            .setPairingSetupEnabled(true)
            .setPairingCacheEnabled(true)
            .setPairingVerificationEnabled(true)
            .setBootstrappingMethods(method)
            .build()
    }

    private fun isHardwareSupported(): Boolean =
        appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)

    private fun AutoCloseable?.closeQuietly() {
        if (this == null) return
        try {
            close()
        } catch (error: Exception) {
            Log.w(TAG, "Aware resource close failed (${error.javaClass.simpleName})")
        }
    }

    companion object {
        private const val TAG = "AwareSession"
        const val SERVICE_NAME = "_goh-tour._tcp"
        const val REALTIME_PORT = 50_000
        const val CONTROL_PORT = 50_001
        const val ASSET_PORT = 50_002
        const val BOOTSTRAP_PORT = 50_003
        private const val CONNECT_TIMEOUT_MILLISECONDS = 5_000
        private const val MAXIMUM_BOOTSTRAP_SIZE = 65_536
    }
}
