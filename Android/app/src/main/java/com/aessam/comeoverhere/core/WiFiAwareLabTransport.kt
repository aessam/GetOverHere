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
import android.os.SystemClock
import android.system.OsConstants
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.ceil

class WiFiAwareLabTransport(context: Context) : AutoCloseable {
    enum class Role { PUBLISHER, SUBSCRIBER }
    enum class Status { IDLE, ATTACHING, ADVERTISING, BROWSING, PAIRING, REQUESTING_DATA_PATH, CONNECTED, FAILED }

    data class CapabilitySnapshot(
        val featureDeclared: Boolean,
        val currentlyAvailable: Boolean,
        val pairingSupported: Boolean,
        val maximumDataPaths: Int,
        val availableDataPaths: Int,
        val maximumPublishSessions: Int,
        val maximumSubscribeSessions: Int,
    )

    data class Snapshot(
        val role: Role = Role.SUBSCRIBER,
        val status: Status = Status.IDLE,
        val capabilities: CapabilitySnapshot,
        val pin: String = DEFAULT_PIN,
        val peerDiscovered: Boolean = false,
        val discoveredPeerCount: Int = 0,
        val connectedPeerCount: Int = 0,
        val pairedAlias: String? = null,
        val peerAddress: String? = null,
        val peerPort: Int? = null,
        val sentFrames: Long = 0,
        val receivedFrames: Long = 0,
        val missingFrames: Long = 0,
        val malformedFrames: Long = 0,
        val p95RoundTripMilliseconds: Double = 0.0,
        val probing: Boolean = false,
        val lastError: String? = null,
        val events: List<String> = emptyList(),
    )

    private val appContext = context.applicationContext
    private val awareManager = appContext.getSystemService(WifiAwareManager::class.java)
    private val connectivityManager = appContext.getSystemService(ConnectivityManager::class.java)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val _snapshot = MutableStateFlow(Snapshot(capabilities = readCapabilities()))
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    private var awareSession: WifiAwareSession? = null
    private var discoverySession: DiscoverySession? = null
    private var discoveredPeer: PeerHandle? = null
    private var discoveredInfo: ServiceDiscoveryInfo? = null
    private val discoveredPeers = ConcurrentHashMap<PeerHandle, ServiceDiscoveryInfo>()
    private val networkCallbacks = ConcurrentHashMap<PeerHandle, ConnectivityManager.NetworkCallback>()
    private val activeNetworks = ConcurrentHashMap<PeerHandle, Network>()
    private val remoteEndpoints = ConcurrentHashMap<String, InetSocketAddress>()
    private var socket: DatagramSocket? = null
    private var receiverJob: Job? = null
    private var probeJob: Job? = null
    private var remoteAddress: Inet6Address? = null
    private var remotePort: Int = 0
    private var nextSequence = 1L
    private var lastReceivedSequence: Long? = null
    private val roundTripSamples = ArrayDeque<Double>()

    fun setRole(role: Role) {
        check(_snapshot.value.status == Status.IDLE || _snapshot.value.status == Status.FAILED) {
            "Stop the current Wi-Fi Aware session before changing role"
        }
        update { it.copy(role = role, lastError = null) }
    }

    fun setPin(pin: String) {
        require(pin.all(Char::isDigit)) { "Pairing PIN must contain only digits" }
        update { it.copy(pin = pin) }
    }

    fun start() {
        stop()
        val capabilities = readCapabilities()
        update { it.copy(capabilities = capabilities, status = Status.ATTACHING, lastError = null) }
        if (!capabilities.featureDeclared) return fail("Device does not declare FEATURE_WIFI_AWARE")
        if (!capabilities.currentlyAvailable) return fail("Wi-Fi Aware is currently unavailable")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return fail("Cross-platform pairing requires Android 14 or later")
        }

        if (_snapshot.value.role == Role.PUBLISHER) {
            socket = DatagramSocket(0).also { startReceiver(it) }
            appendEvent("Publisher UDP port ${socket?.localPort}")
        }

        try {
            awareManager.attach(object : AttachCallback() {
                override fun onAttached(session: WifiAwareSession) {
                    awareSession = session
                    update { it.copy(capabilities = readCapabilities()) }
                    appendEvent("Attached to Wi-Fi Aware")
                    startDiscovery(session)
                }

                override fun onAttachFailed() {
                    fail("Wi-Fi Aware attach failed")
                }
            }, mainHandler)
        } catch (error: SecurityException) {
            fail("Wi-Fi Aware permission denied: ${error.message}")
        } catch (error: RuntimeException) {
            fail("Wi-Fi Aware attach failed: ${error.message}")
        }
    }

    fun pair() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return fail("Pairing requires Android 14 or later")
        }
        val session = discoverySession ?: return fail("Discovery session is not ready")
        val peer = discoveredPeer ?: return fail("No peer has been discovered")
        val pin = _snapshot.value.pin
        if (pin.isBlank()) return fail("Enter the PIN shown by the publisher")

        update { it.copy(status = Status.PAIRING, lastError = null) }
        val advertisedMethods = discoveredInfo?.pairingConfig?.bootstrappingMethods ?: 0
        val keypad = AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD
        if (advertisedMethods and keypad != 0) {
            appendEvent("Starting PIN keypad bootstrapping")
            session.initiateBootstrappingRequest(peer, keypad)
        } else {
            appendEvent("Starting pairing setup without bootstrapping")
            initiatePairing(session, peer)
        }
    }

    fun toggleProbe() {
        if (_snapshot.value.probing) {
            probeJob?.cancel()
            probeJob = null
            update { it.copy(probing = false) }
            appendEvent("Probe stopped")
            return
        }
        if (socket == null || (remoteEndpoints.isEmpty() && (remoteAddress == null || remotePort == 0))) {
            return fail("No connected UDP peer for probe")
        }

        update { it.copy(probing = true, lastError = null) }
        appendEvent("20 ms probe started, $PAYLOAD_SIZE-byte payload")
        probeJob = scope.launch(Dispatchers.IO) {
            try {
                while (isActive) {
                    sendProbe()
                    delay(PROBE_INTERVAL_MILLISECONDS)
                }
            } catch (_: CancellationException) {
                return@launch
            } catch (error: Exception) {
                fail("Probe failed: ${error.message}")
            }
        }
    }

    fun resetMetrics() {
        nextSequence = 1
        lastReceivedSequence = null
        roundTripSamples.clear()
        update {
            it.copy(
                sentFrames = 0,
                receivedFrames = 0,
                missingFrames = 0,
                malformedFrames = 0,
                p95RoundTripMilliseconds = 0.0,
            )
        }
        appendEvent("Metrics reset")
    }

    fun stop() {
        probeJob?.cancel()
        probeJob = null
        receiverJob?.cancel()
        receiverJob = null
        socket?.close()
        socket = null
        networkCallbacks.values.toList().forEach {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "Network callback was already unregistered (${error.javaClass.simpleName})")
            }
        }
        networkCallbacks.clear()
        activeNetworks.clear()
        remoteEndpoints.clear()
        discoverySession?.close()
        discoverySession = null
        awareSession?.close()
        awareSession = null
        discoveredPeer = null
        discoveredInfo = null
        discoveredPeers.clear()
        remoteAddress = null
        remotePort = 0
        update {
            it.copy(
                status = Status.IDLE,
                peerDiscovered = false,
                discoveredPeerCount = 0,
                connectedPeerCount = 0,
                pairedAlias = null,
                peerAddress = null,
                peerPort = null,
                probing = false,
            )
        }
    }

    override fun close() {
        stop()
        scope.cancel()
    }

    private fun startDiscovery(session: WifiAwareSession) {
        val pairingConfig = pairingConfig(_snapshot.value.role)
        val callback = discoveryCallback()
        if (_snapshot.value.role == Role.PUBLISHER) {
            val config = PublishConfig.Builder()
                .setServiceName(SERVICE_NAME)
                .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED)
                .setPairingConfig(pairingConfig)
                .build()
            session.publish(config, callback, mainHandler)
        } else {
            val config = SubscribeConfig.Builder()
                .setServiceName(SERVICE_NAME)
                .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE)
                .setPairingConfig(pairingConfig)
                .build()
            session.subscribe(config, callback, mainHandler)
        }
    }

    private fun discoveryCallback() = object : DiscoverySessionCallback() {
        override fun onPublishStarted(session: PublishDiscoverySession) {
            discoverySession = session
            update { it.copy(status = Status.ADVERTISING) }
            appendEvent("Publishing $SERVICE_NAME")
        }

        override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
            discoverySession = session
            update { it.copy(status = Status.BROWSING) }
            appendEvent("Subscribing to $SERVICE_NAME")
        }

        override fun onSessionConfigFailed() {
            fail("Wi-Fi Aware discovery configuration failed")
        }

        override fun onSessionTerminated() {
            fail("Wi-Fi Aware discovery session terminated")
        }

        override fun onServiceDiscovered(info: ServiceDiscoveryInfo) {
            discoveredPeer = info.peerHandle
            discoveredInfo = info
            discoveredPeers[info.peerHandle] = info
            update {
                it.copy(
                    peerDiscovered = true,
                    discoveredPeerCount = discoveredPeers.size,
                    pairedAlias = info.pairedAlias,
                )
            }
            appendEvent(
                "Peer discovered; cipher=${info.peerCipherSuite}, scid=${info.scid?.size ?: 0} bytes"
            )
            if (info.pairedAlias != null) {
                appendEvent("Existing pairing found; waiting for verification")
            }
        }

        override fun onPairingSetupRequestReceived(peerHandle: PeerHandle, requestId: Int) {
            discoveredPeer = peerHandle
            val session = discoverySession ?: return fail("Pairing request arrived without a session")
            val pin = _snapshot.value.pin
            if (pin.isBlank()) return fail("Pairing request received but PIN is empty")
            update { it.copy(status = Status.PAIRING, peerDiscovered = true) }
            appendEvent("Accepting pairing request $requestId")
            session.acceptPairingRequest(
                requestId,
                peerHandle,
                PEER_ALIAS,
                Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128,
                pin,
            )
        }

        override fun onBootstrappingSucceeded(peerHandle: PeerHandle, method: Int) {
            appendEvent("Bootstrapping succeeded: $method")
            val session = discoverySession ?: return fail("Bootstrapping succeeded without a session")
            initiatePairing(session, peerHandle)
        }

        override fun onBootstrappingFailed(peerHandle: PeerHandle) {
            fail("Wi-Fi Aware bootstrapping failed")
        }

        override fun onPairingSetupSucceeded(peerHandle: PeerHandle, alias: String) {
            discoveredPeer = peerHandle
            update { it.copy(pairedAlias = alias) }
            appendEvent("Pairing succeeded: $alias")
            requestDataPath(peerHandle)
        }

        override fun onPairingSetupFailed(peerHandle: PeerHandle) {
            fail("Wi-Fi Aware pairing setup failed")
        }

        override fun onPairingVerificationSucceed(peerHandle: PeerHandle, alias: String) {
            discoveredPeer = peerHandle
            update { it.copy(pairedAlias = alias) }
            appendEvent("Pairing verified: $alias")
            requestDataPath(peerHandle)
        }

        override fun onPairingVerificationFailed(peerHandle: PeerHandle) {
            fail("Wi-Fi Aware pairing verification failed")
        }
    }

    private fun pairingConfig(role: Role): AwarePairingConfig {
        val method = if (role == Role.PUBLISHER) {
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

    private fun initiatePairing(session: DiscoverySession, peer: PeerHandle) {
        session.initiatePairingRequest(
            peer,
            PEER_ALIAS,
            Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128,
            _snapshot.value.pin,
        )
        appendEvent("Pairing request sent")
    }

    private fun requestDataPath(peer: PeerHandle) {
        if (networkCallbacks.containsKey(peer)) return
        val session = discoverySession ?: return fail("Cannot request data path without discovery")
        update { it.copy(status = Status.REQUESTING_DATA_PATH) }

        val specifierBuilder = WifiAwareNetworkSpecifier.Builder(session, peer)
        if (_snapshot.value.role == Role.PUBLISHER) {
            val port = socket?.localPort
            if (port == null || port <= 0) {
                return fail("Publisher UDP socket is unavailable")
            }
            specifierBuilder
                .setPort(port)
                .setTransportProtocol(OsConstants.IPPROTO_UDP)
            appendEvent("Advertising UDP port $port in NDP")
        }
        val specifier = specifierBuilder.build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                activeNetworks[peer] = network
                appendEvent("NAN data path available")
                inspectNetwork(peer, network)
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                inspectNetwork(peer, network, capabilities)
            }

            override fun onLost(network: Network) {
                activeNetworks.remove(peer)
                update {
                    it.copy(
                        connectedPeerCount = activeNetworks.size,
                        status = if (activeNetworks.isEmpty()) {
                            if (it.role == Role.PUBLISHER) Status.ADVERTISING else Status.BROWSING
                        } else {
                            Status.CONNECTED
                        },
                    )
                }
                appendEvent("NAN data path lost; ${activeNetworks.size} remain")
            }

            override fun onUnavailable() {
                networkCallbacks.remove(peer)
                appendEvent("NAN data path request unavailable")
            }
        }
        networkCallbacks[peer] = callback
        try {
            connectivityManager.requestNetwork(request, callback, mainHandler)
        } catch (error: RuntimeException) {
            networkCallbacks.remove(peer)
            fail("NAN data path request failed: ${error.message}")
        }
    }

    private fun inspectNetwork(
        peer: PeerHandle,
        network: Network,
        capabilities: NetworkCapabilities? = null,
    ) {
        val actualCapabilities = capabilities ?: connectivityManager.getNetworkCapabilities(network) ?: return
        val info = actualCapabilities.transportInfo as? WifiAwareNetworkInfo ?: return
        val address = info.peerIpv6Addr ?: return fail("NAN data path has no peer IPv6 address")
        val port = info.port
        update {
            it.copy(
                peerAddress = address.hostAddress,
                peerPort = port.takeIf { value -> value > 0 },
            )
        }
        appendEvent("NDP peer ${address.hostAddress}; port=$port protocol=${info.transportProtocol}")
        activeNetworks[peer] = network

        remoteAddress = address
        if (_snapshot.value.role == Role.SUBSCRIBER) {
            if (port <= 0) return fail("Publisher did not advertise a UDP port")
            remotePort = port
            if (socket == null) {
                val connectedSocket = DatagramSocket(null)
                network.bindSocket(connectedSocket)
                connectedSocket.connect(InetSocketAddress(address, port))
                socket = connectedSocket
                startReceiver(connectedSocket)
                update { it.copy(status = Status.CONNECTED, connectedPeerCount = activeNetworks.size) }
                appendEvent("UDP connected")
                scope.launch(Dispatchers.IO) { sendHello() }
            }
        } else {
            update { it.copy(status = Status.CONNECTED, connectedPeerCount = activeNetworks.size) }
        }
    }

    private fun startReceiver(datagramSocket: DatagramSocket) {
        receiverJob?.cancel()
        receiverJob = scope.launch(Dispatchers.IO) {
            val buffer = ByteArray(MAX_DATAGRAM_SIZE)
            while (isActive && !datagramSocket.isClosed) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    datagramSocket.receive(packet)
                    val packetAddress = packet.address as? Inet6Address
                    if (packetAddress != null) {
                        remoteAddress = packetAddress
                        remotePort = packet.port
                        remoteEndpoints["${packetAddress.hostAddress}:${packet.port}"] =
                            InetSocketAddress(packetAddress, packet.port)
                        update {
                            it.copy(
                                connectedPeerCount = activeNetworks.size,
                                status = Status.CONNECTED,
                            )
                        }
                    }
                    handleDatagram(datagramSocket, packet)
                } catch (_: CancellationException) {
                    return@launch
                } catch (error: Exception) {
                    if (!datagramSocket.isClosed) fail("UDP receive failed: ${error.message}")
                    return@launch
                }
            }
        }
    }

    private fun handleDatagram(datagramSocket: DatagramSocket, packet: DatagramPacket) {
        val frame = try {
            WiFiAwareProbeFrame.decode(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
        } catch (error: WiFiAwareProbeFrame.DecodeException) {
            update { it.copy(malformedFrames = it.malformedFrames + 1) }
            Log.e(TAG, "Malformed probe frame (${error.javaClass.simpleName})")
            return
        }

        update { it.copy(receivedFrames = it.receivedFrames + 1) }

        when (frame.kind) {
            WiFiAwareProbeFrame.Kind.HELLO -> appendEvent("Hello received")
            WiFiAwareProbeFrame.Kind.PROBE -> {
                update {
                    val missing = lastReceivedSequence
                        ?.takeIf { previous -> frame.sequence > previous + 1 }
                        ?.let { previous -> frame.sequence - previous - 1 }
                        ?: 0
                    lastReceivedSequence = maxOf(lastReceivedSequence ?: 0, frame.sequence)
                    it.copy(missingFrames = it.missingFrames + missing)
                }
                val echo = frame.copy(kind = WiFiAwareProbeFrame.Kind.ECHO).encode()
                val response = DatagramPacket(echo, echo.size, packet.address, packet.port)
                datagramSocket.send(response)
                update { it.copy(sentFrames = it.sentFrames + 1, status = Status.CONNECTED) }
            }
            WiFiAwareProbeFrame.Kind.ECHO -> recordRoundTrip(frame.sentAtNanoseconds)
        }
    }

    private fun sendHello() {
        val frame = WiFiAwareProbeFrame(
            kind = WiFiAwareProbeFrame.Kind.HELLO,
            sequence = 0,
            sentAtNanoseconds = SystemClock.elapsedRealtimeNanos(),
            payload = ByteArray(0),
        )
        send(frame)
    }

    private fun sendProbe() {
        val sequence = nextSequence++
        val frame = WiFiAwareProbeFrame(
            kind = WiFiAwareProbeFrame.Kind.PROBE,
            sequence = sequence,
            sentAtNanoseconds = SystemClock.elapsedRealtimeNanos(),
            payload = ByteArray(PAYLOAD_SIZE) { sequence.toByte() },
        )
        send(frame)
    }

    private fun send(frame: WiFiAwareProbeFrame) {
        val datagramSocket = socket ?: throw IllegalStateException("UDP socket is unavailable")
        val bytes = frame.encode()
        if (datagramSocket.isConnected) {
            datagramSocket.send(DatagramPacket(bytes, bytes.size))
        } else {
            val endpoints = remoteEndpoints.values.toList()
            if (endpoints.isEmpty()) {
                val address = remoteAddress ?: throw IllegalStateException("Peer address is unavailable")
                if (remotePort <= 0) throw IllegalStateException("Peer port is unavailable")
                datagramSocket.send(DatagramPacket(bytes, bytes.size, address, remotePort))
            } else {
                endpoints.forEach { endpoint ->
                    datagramSocket.send(
                        DatagramPacket(bytes, bytes.size, endpoint.address, endpoint.port),
                    )
                }
            }
        }
        val copies = if (datagramSocket.isConnected) 1 else maxOf(1, remoteEndpoints.size)
        update { it.copy(sentFrames = it.sentFrames + copies) }
    }

    private fun recordRoundTrip(sentAtNanoseconds: Long) {
        val elapsed = SystemClock.elapsedRealtimeNanos() - sentAtNanoseconds
        if (elapsed < 0) return
        roundTripSamples.addLast(elapsed / 1_000_000.0)
        while (roundTripSamples.size > MAX_RTT_SAMPLES) roundTripSamples.removeFirst()
        val sorted = roundTripSamples.sorted()
        val index = maxOf(0, ceil(sorted.size * 0.95).toInt() - 1)
        update { it.copy(p95RoundTripMilliseconds = sorted[index]) }
    }

    private fun readCapabilities(): CapabilitySnapshot {
        val feature = appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
        val characteristics = awareManager.characteristics
        val resources = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            awareManager.availableAwareResources
        } else {
            null
        }
        return CapabilitySnapshot(
            featureDeclared = feature,
            currentlyAvailable = feature && awareManager.isAvailable,
            pairingSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                characteristics?.isAwarePairingSupported == true,
            maximumDataPaths = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                characteristics?.numberOfSupportedDataPaths ?: 0
            } else {
                0
            },
            availableDataPaths = resources?.availableDataPathsCount ?: 0,
            maximumPublishSessions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                characteristics?.numberOfSupportedPublishSessions ?: 0
            } else {
                0
            },
            maximumSubscribeSessions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                characteristics?.numberOfSupportedSubscribeSessions ?: 0
            } else {
                0
            },
        )
    }

    private fun fail(message: String) {
        update { it.copy(status = Status.FAILED, lastError = message, probing = false) }
        appendEvent(message)
    }

    private fun appendEvent(message: String) {
        update { state -> state.copy(events = (listOf(message) + state.events).take(MAX_EVENTS)) }
    }

    private inline fun update(transform: (Snapshot) -> Snapshot) {
        _snapshot.update(transform)
    }

    companion object {
        private const val TAG = "WiFiAwareLab"
        private const val SERVICE_NAME = "_goh-probe._udp"
        private const val PEER_ALIAS = "GetOverHere peer"
        private const val DEFAULT_PIN = "314159"
        private const val PAYLOAD_SIZE = 45
        private const val PROBE_INTERVAL_MILLISECONDS = 20L
        private const val MAX_DATAGRAM_SIZE = 2_048
        private const val MAX_RTT_SAMPLES = 1_000
        private const val MAX_EVENTS = 80
    }
}
