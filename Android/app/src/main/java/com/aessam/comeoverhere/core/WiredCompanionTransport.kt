package com.aessam.comeoverhere.core

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.KeyInfo
import android.util.Log
import com.aessam.toursession.GatewayLane
import com.aessam.toursession.GatewayLaneRequest
import com.aessam.toursession.GatewayPairingMessage
import com.aessam.toursession.GatewayPairingRole
import com.aessam.toursession.GatewayProtocol
import com.aessam.toursession.GatewayRoomDescriptor
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.math.BigInteger
import java.net.InetAddress
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Principal
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

fun interface GuideLaneConnector { fun connect(lane: GatewayLane): NearbyByteConnection }

data class WiredRouteDiagnostic(val interfaceName: String, val localAddress: String, val remoteAddress: String,
    val localPort: Int, val remotePort: Int, val generation: Long?, val connected: Boolean,
    val selectedSourceMatches: Boolean)

/** Enumerates wired-looking public interfaces; actual route is retained for qualification. */
data class WiredInterfaceAddress(val interfaceName: String, val address: InetAddress, val prefixLength: Short) {
    val displayName: String get() = "$interfaceName: ${address.hostAddress}"
    fun contains(peer: InetAddress): Boolean {
        val local = address.address; val remote = peer.address
        if (local.size != remote.size || prefixLength <= 0 || prefixLength > local.size * 8) return false
        return local.indices.all { index ->
            val remaining = prefixLength - index * 8
            val mask = if (remaining >= 8) 255 else if (remaining <= 0) 0 else (255 shl (8 - remaining)) and 255
            (local[index].toInt() and mask) == (remote[index].toInt() and mask)
        }
    }
    companion object {
        fun available(): List<WiredInterfaceAddress> = NetworkInterface.getNetworkInterfaces().toList().flatMap { nic ->
            // Never select wlan, mobile, VPN, loopback or a VM network as USB fallback.
            val wiredName = listOf("ncm", "rndis", "usb", "eth", "en").any(nic.name::startsWith)
            if (!wiredName || !nic.isUp || nic.isLoopback) emptyList() else nic.interfaceAddresses.mapNotNull {
                if (it.address.isLoopbackAddress || it.address.isAnyLocalAddress || it.networkPrefixLength <= 0 ||
                    it.networkPrefixLength > it.address.address.size * 8) null
                else WiredInterfaceAddress(nic.name, it.address, it.networkPrefixLength)
            }
        }
    }
}

/** Pin the complete leaf certificate and let TLS prove possession; system roots are irrelevant. */
internal class HubCertificateTrust(expected: ByteArray) : X509TrustManager {
    private val expected = expected.copyOf()
    init { require(expected.size == 32) }
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
    private fun check(chain: Array<out X509Certificate>?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("Missing companion certificate")
        leaf.checkValidity()
        if (!MessageDigest.isEqual(expected, MessageDigest.getInstance("SHA-256").digest(leaf.encoded)))
            throw CertificateException("Companion certificate does not match scanned fingerprint")
    }
}

internal class HubIdentity(private val alias: String = DEFAULT_ALIAS, renewExpiredForEnrollment: Boolean = false) {
    private val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    init {
        check(Build.VERSION.SDK_INT >= 29) { "Companion mode requires Android 10 TLS 1.3" }
        val existing = store.getCertificate(alias) as? X509Certificate
        val expired = existing?.notAfter?.let { !it.after(Date()) } == true
        check(!expired || renewExpiredForEnrollment) {
            "Companion certificate expired. Remove the association and start a new two-way enrollment."
        }
        if (existing != null && !expired) existing.checkValidity()
        if (!store.containsAlias(alias) || expired) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    // JSSE hashes the TLS transcript itself and uses NONEwithECDSA for
                    // AndroidKeyStore's private-key upcall; SHA256 also signs the certificate.
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                    .setCertificateSubject(X500Principal("CN=GetOverHere wired hub"))
                    .setCertificateSerialNumber(BigInteger(128, SecureRandom()).abs().add(BigInteger.ONE))
                    .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000))
                    .setCertificateNotAfter(Date(System.currentTimeMillis() + 5L * 365 * 86_400_000))
                    .build())
                generateKeyPair()
            }
        }
        val privateKey = store.getKey(alias, null) as PrivateKey
        val policy = KeyFactory.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            .getKeySpec(privateKey, KeyInfo::class.java)
        check(KeyProperties.DIGEST_NONE in policy.digests) {
            "Existing hub identity cannot sign TLS transcripts. Remove its enrollment and explicitly reprovision; its certificate was not rotated."
        }
    }
    val fingerprint: ByteArray get() = MessageDigest.getInstance("SHA-256").digest(store.getCertificate(alias).encoded)
    fun context(peerPin: ByteArray): SSLContext {
        val key = store.getKey(alias, null) as PrivateKey
        val chain = store.getCertificateChain(alias).map { it as X509Certificate }.toTypedArray()
        val manager = object : X509ExtendedKeyManager() {
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
                if (keyType == "EC") arrayOf(alias) else null
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? =
                if (keyType?.contains("EC") == true) alias else null
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = getClientAliases(keyType, issuers)
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? =
                if (keyType == "EC") alias else null
            override fun chooseEngineClientAlias(keyTypes: Array<out String>?, issuers: Array<out Principal>?, engine: javax.net.ssl.SSLEngine?): String? =
                if (keyTypes?.contains("EC") == true) alias else null
            override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: javax.net.ssl.SSLEngine?): String? =
                if (keyType == "EC") alias else null
            override fun getCertificateChain(requested: String?): Array<X509Certificate>? = if (requested == alias) chain else null
            override fun getPrivateKey(requested: String?): PrivateKey? = if (requested == alias) key else null
        }
        return SSLContext.getInstance("TLSv1.3").apply {
            init(arrayOf<KeyManager>(manager), arrayOf<TrustManager>(HubCertificateTrust(peerPin)), SecureRandom())
        }
    }
    companion object { const val DEFAULT_ALIAS = "goh.wired.hub.tls13.v1" }
}

/** TLS transport never creates guide authority, credentials, codecs or arbitrary destinations. */
class WiredCompanionTransport internal constructor(private val identityAlias: String = HubIdentity.DEFAULT_ALIAS,
    private val enableAddressRecovery: Boolean = true,
    private val discovery: WiredHubDiscoveryInterface = WiredHubDiscovery(),
    private val availableInterfaces: () -> List<WiredInterfaceAddress> = WiredInterfaceAddress::available,
    private val clock: () -> Long = System::currentTimeMillis,
    private val beforeDescriptorCommit: () -> Unit = {},
    private val beforeAccept: () -> Unit = {}) : Closeable, GuideLaneConnector,
    GatewayWiredInterface {
    override var onDescriptor: ((GatewayRoomDescriptor?) -> Unit)? = null
    override var onError: ((String) -> Unit)? = null
    override var onConnected: ((Boolean) -> Unit)? = null
    override var onRecoveryChanged: ((GatewayRecoveryState) -> Unit)? = null
    private var enrolledIdentity: HubIdentity? = null
    private val identity: HubIdentity get() = enrolledIdentity ?: HubIdentity(identityAlias).also { enrolledIdentity = it }
    private val io = Executors.newCachedThreadPool { body -> Thread(body, "wired-hub").apply { isDaemon = true } }
    private val timer = Executors.newSingleThreadScheduledExecutor { body -> Thread(body, "wired-deadline").apply { isDaemon = true } }
    private val recoveryMonitor = Executors.newSingleThreadScheduledExecutor { body -> Thread(body, "wired-interface-monitor").apply { isDaemon = true } }
    private val operation = AtomicLong()
    private val rejectedConnections = AtomicLong()
    private val sockets = ConcurrentHashMap.newKeySet<Closeable>()
    private val pendingHandshake = Semaphore(8)
    private val pendingAdmission = Semaphore(GatewayProtocol.FORWARDED_ADMISSION_LIMIT)
    private val persistent = Semaphore(90) // 30 listeners × 3 independent persistent application lanes.
    private val ingress = NearbySocketBridge(audioResidenceMilliseconds = GatewayProtocol.AUDIO_RESIDENCE_MILLISECONDS,
        reliableWriteTimeoutMilliseconds = 5_000)
    private var server: SSLServerSocket? = null
    @Volatile private var offer: GatewayPairingMessage? = null
    @Volatile private var response: GatewayPairingMessage? = null
    @Volatile private var context: SSLContext? = null
    @Volatile private var selectedInterface: WiredInterfaceAddress? = null
    @Volatile private var descriptor: GatewayRoomDescriptor? = null
    @Volatile private var control: SSLSocket? = null
    private var connectingControl = false
    @Volatile private var guideDescriptor: (() -> GatewayRoomDescriptor?)? = null
    @Volatile private var lastRoute: WiredRouteDiagnostic? = null
    private var recoveryTask: ScheduledFuture<*>? = null
    private var enrolledInterfaceName: String? = null
    private var enrolledAddressSize = 0
    private var nextReconnectAt = 0L
    private var reconnectFailures = 0
    private var associationAuthenticated = false
    private var enrollmentStartedAt = 0L
    @Volatile private var peerHost: String? = null
    override val automaticRecoveryEnabled: Boolean get() = enableAddressRecovery && recoveryTask != null
    override val routeDescription: String? get() = selectedInterface?.displayName
    override val isConnected: Boolean get() = control?.let { !it.isClosed } == true
    override fun routeSnapshot(): WiredRouteDiagnostic? = lastRoute?.copy(connected = isConnected, generation = descriptor?.generation)
    fun rejectedConnectionCount(): Long = rejectedConnections.get()
    private fun recordRoute(socket: Socket) {
        val selected = requireNotNull(selectedInterface)
        validateInterface(selected)
        check(socket.localAddress == selected.address) { "Wired control used a different source interface" }
        validatePeerRoute(selected, socket.inetAddress)
        lastRoute = WiredRouteDiagnostic(selected.interfaceName, requireNotNull(socket.localAddress.hostAddress),
            requireNotNull(socket.inetAddress.hostAddress), socket.localPort, socket.port, descriptor?.generation, true, true)
    }
    init {
        discovery.onCandidate = { pair, local, host ->
            synchronized(this) {
                if (automaticRecoveryEnabled && offer?.pairingID == pair && guideDescriptor == null && selectedInterface == local && !isConnected) {
                    val candidate = host?.let { requireNotNull(numericAddress(it, local).hostAddress) }
                    if (candidate != peerHost) { reconnectFailures = 0; nextReconnectAt = 0 }
                    peerHost = candidate
                }
            }
        }
        discovery.onError = { message -> if (automaticRecoveryEnabled) {
            Log.w("WiredHub", "Wired address recovery failed")
            if (!isConnected) onError?.invoke("Wired address recovery: $message")
        } }
    }

    @Synchronized override fun makeOffer(record: com.aessam.toursession.BluetoothRoomRecord, key: ByteArray,
                                address: WiredInterfaceAddress, current: () -> GatewayRoomDescriptor?): GatewayPairingMessage {
        stop()
        enrolledIdentity = HubIdentity(identityAlias, renewExpiredForEnrollment = true)
        enrollmentStartedAt = System.nanoTime()
        selectedInterface = address; guideDescriptor = current
        enrolledInterfaceName = address.interfaceName; enrolledAddressSize = address.address.address.size
        return GatewayPairingMessage(GatewayPairingRole.OFFER, UUID.randomUUID(), record.roomID, record.guideID,
            clock() + GatewayProtocol.ENROLLMENT_LIFETIME_MILLISECONDS, identity.fingerprint,
            MessageDigest.getInstance("SHA-256").digest(key), identity.fingerprint,
            requireNotNull(address.address.hostAddress), GatewayProtocol.PORT).also { offer = GatewayPairingMessage.decode(it.encode()) }
    }

    @Synchronized override fun answerOffer(message: GatewayPairingMessage, address: WiredInterfaceAddress): GatewayPairingMessage {
        stop(); message.validateReceivedOffer(clock())
        enrolledIdentity = HubIdentity(identityAlias, renewExpiredForEnrollment = true)
        enrollmentStartedAt = System.nanoTime()
        require(message.role == GatewayPairingRole.OFFER)
        val peer = numericAddress(message.host, address)
        require(address.contains(peer)) { "Scanned guide is not on the selected wired interface" }
        selectedInterface = address; offer = GatewayPairingMessage.decode(message.encode())
        enrolledInterfaceName = address.interfaceName; enrolledAddressSize = address.address.address.size
        peerHost = requireNotNull(peer.hostAddress)
        return message.copy(role = GatewayPairingRole.RESPONSE, certificateFingerprint = identity.fingerprint,
            host = "", port = 0).also { response = it; context = identity.context(message.certificateFingerprint) }
    }

    @Synchronized override fun confirmResponse(message: GatewayPairingMessage) {
        val currentOffer = requireNotNull(offer) { "Create an offer first" }
        currentOffer.validateResponse(message, clock())
        check(server == null) { "Companion already confirmed" }
        response = message; context = identity.context(message.certificateFingerprint)
        listenForConfirmedCompanion()
        startRecovery()
    }

    @Synchronized private fun listenForConfirmedCompanion() {
        check(response != null && guideDescriptor != null) { "Companion is not confirmed" }
        check(server == null)
        val currentOffer = requireNotNull(offer)
        if (!associationAuthenticated) currentOffer.validate(clock())
        validateInterface(requireNotNull(selectedInterface))
        val attempt = operation.get()
        val listener = (requireNotNull(context).serverSocketFactory.createServerSocket() as SSLServerSocket).apply {
            reuseAddress = true; enabledProtocols = arrayOf("TLSv1.3"); needClientAuth = true
            bind(InetSocketAddress(requireNotNull(selectedInterface).address, currentOffer.port), 8)
        }
        server = listener; sockets.add(listener)
        io.execute {
            try {
                while (operation.get() == attempt) {
                    beforeAccept()
                    val socket = listener.accept() as SSLSocket
                    if (!pendingHandshake.tryAcquire()) { socket.close(); continue }
                    sockets.add(socket)
                    io.execute { receive(socket, attempt) }
                }
            } catch (error: Exception) { synchronized(this) {
                if (operation.get() == attempt && server === listener) {
                    server = null; sockets.remove(listener)
                    try { listener.close() } catch (closeError: Exception) {
                        Log.w("WiredHub", "Failed listener cleanup (${closeError.javaClass.simpleName})")
                    }
                    fail(error) // The recovery monitor can now bind a replacement on the same interface.
                }
            } }
        }
    }

    @Synchronized override fun startCompanion() {
        startCompanionAttempt(resetBudget = true)
    }
    @Synchronized private fun startCompanionAttempt(resetBudget: Boolean) {
        // UI retry is idempotent while the native owner is already connecting.
        if (control != null || connectingControl) return
        if (!associationAuthenticated) {
            requireNotNull(offer).validateReceivedOffer(clock())
            check(System.nanoTime() - enrollmentStartedAt < TimeUnit.MILLISECONDS.toNanos(GatewayProtocol.ENROLLMENT_LIFETIME_MILLISECONDS)) {
                "Incomplete companion enrollment expired. Scan a new QR."
            }
        }
        if (resetBudget) reconnectFailures = 0
        startRecovery()
        val attempt = operation.get()
        check(response != null && guideDescriptor == null) { "Scan the guide offer before connecting" }
        connectingControl = true
        onRecoveryChanged?.invoke(GatewayRecoveryState.CONNECTING)
        io.execute {
            var authenticated = false
            var ownedUpstream: SSLSocket? = null
            try {
                val upstream = open(GatewayLane.HUB_CONTROL, 0, attempt)
                ownedUpstream = upstream
                synchronized(this) {
                    check(operation.get() == attempt && control == null) { "Companion operation replaced" }
                    control = upstream
                    recordRoute(upstream)
                }
                upstream.soTimeout = GatewayProtocol.HEARTBEAT_TIMEOUT_MILLISECONDS
                val input = DataInputStream(upstream.inputStream)
                while (operation.get() == attempt) {
                    val length = input.readUnsignedShort()
                    require(length in 1..GatewayProtocol.MAXIMUM_DESCRIPTOR_SIZE)
                    val next = GatewayRoomDescriptor.decode(ByteArray(length).also(input::readFully))
                    next.validate(requireNotNull(offer))
                    beforeDescriptorCommit()
                    synchronized(this) {
                        check(operation.get() == attempt && control === upstream) { "Descriptor belongs to a replaced USB association" }
                        val previous = descriptor
                        if (previous != null) require(next.generation == previous.generation && next.recordRevision >= previous.recordRevision)
                        if (previous != null && next.recordRevision == previous.recordRevision)
                            require(next.encode().contentEquals(previous.encode())) { "Descriptor changed without a revision" }
                        descriptor = GatewayRoomDescriptor.decode(next.encode())
                        authenticated = true; associationAuthenticated = true; reconnectFailures = 0
                    }
                    val acknowledgementDeadline = timer.schedule({ upstream.close() },
                        GatewayProtocol.HEARTBEAT_TIMEOUT_MILLISECONDS.toLong(), TimeUnit.MILLISECONDS)
                    try { upstream.outputStream.write(0); upstream.outputStream.flush() }
                    finally { acknowledgementDeadline.cancel(false) }
                    synchronized(this) {
                        check(operation.get() == attempt && control === upstream) { "Descriptor acknowledgement belongs to a replaced USB association" }
                        onDescriptor?.invoke(next); onConnected?.invoke(true)
                        onRecoveryChanged?.invoke(GatewayRecoveryState.CONNECTED)
                    }
                }
            } catch (error: Exception) {
                synchronized(this) {
                    if (operation.get() == attempt && (control === ownedUpstream || control == null)) {
                        reconnectFailures = if (authenticated) 0 else (reconnectFailures + 1).coerceAtMost(5)
                        disconnect()
                        if (reconnectFailures == 5) fail(IllegalStateException("Wired reconnect attempts exhausted. Check USB and tap Connect to retry."))
                        else fail(error)
                    }
                }
            } finally { synchronized(this) { if (operation.get() == attempt) {
                connectingControl = false
                if (!isConnected) onRecoveryChanged?.invoke(
                    if (reconnectFailures >= 5) GatewayRecoveryState.EXHAUSTED else GatewayRecoveryState.WAITING)
            } } }
        }
    }

    override fun connect(lane: GatewayLane): NearbyByteConnection {
        require(lane != GatewayLane.HUB_CONTROL)
        val current = requireNotNull(descriptor) { "Wired guide is unavailable" }
        val attempt = operation.get()
        val socket = open(lane, current.generation, attempt)
        if (attempt != operation.get() || descriptor?.generation != current.generation) {
            socket.close(); error("Wired route changed during connection")
        }
        return object : NearbyByteConnection {
            override val input get() = socket.inputStream
            override val output get() = socket.outputStream
            override fun close() { sockets.remove(socket); socket.close() }
        }
    }

    private data class OpenTarget(val enrollment: GatewayPairingMessage, val local: WiredInterfaceAddress,
                                  val peerHost: String, val context: SSLContext)
    private fun open(lane: GatewayLane, generation: Long, attempt: Long): SSLSocket {
        val target = synchronized(this) {
            check(operation.get() == attempt) { "USB operation replaced before opening lane" }
            val enrollment = requireNotNull(offer)
            OpenTarget(enrollment, requireNotNull(selectedInterface), peerHost ?: enrollment.host, requireNotNull(context))
        }
        val enrollment = target.enrollment
        val local = target.local
        validateInterface(local)
        val peer = numericAddress(target.peerHost, local)
        require(local.contains(peer)) { "Guide address left the selected wired subnet" }
        validatePeerRoute(local, peer)
        val socket = target.context.socketFactory.createSocket() as SSLSocket
        val deadline = timer.schedule({
            try { socket.close() } catch (error: Exception) { Log.w("WiredHub", "Open deadline cleanup failed (${error.javaClass.simpleName})") }
        }, 5, TimeUnit.SECONDS)
        try {
            synchronized(this) { check(operation.get() == attempt); sockets.add(socket) }
            socket.enabledProtocols = arrayOf("TLSv1.3"); socket.tcpNoDelay = true; socket.soTimeout = 5_000
            socket.bind(InetSocketAddress(local.address, 0))
            socket.connect(InetSocketAddress(peer, enrollment.port), 5_000)
            validateInterface(local)
            check(socket.localAddress == local.address) { "Socket left selected USB source address" }
            socket.startHandshake()
            check(operation.get() == attempt) { "USB operation replaced during TLS handshake" }
            validatePeerRoute(local, socket.inetAddress)
            socket.outputStream.write(GatewayLaneRequest(enrollment.pairingID, enrollment.roomID, generation, lane).encode())
            socket.outputStream.flush()
            check(socket.inputStream.read() == 0) { "Guide rejected companion lane or capacity reached" }
            socket.soTimeout = 0
            return socket
        } catch (error: Exception) { sockets.remove(socket); socket.close(); throw error }
        finally { deadline.cancel(false) }
    }

    private fun receive(socket: SSLSocket, attempt: Long) {
        var lease: Semaphore? = null
        var handshakeReleased = false
        var tlsAuthenticated = false
        val pendingLocal = java.util.concurrent.atomic.AtomicReference<Socket?>()
        val timedOut = java.util.concurrent.atomic.AtomicBoolean(false)
        val deadline = timer.schedule({
            timedOut.set(true)
            try { socket.close() } catch (error: Exception) { Log.w("WiredHub", "Handshake deadline cleanup failed (${error.javaClass.simpleName})") }
            try { pendingLocal.get()?.close() } catch (error: Exception) { Log.w("WiredHub", "Local connect deadline cleanup failed (${error.javaClass.simpleName})") }
        }, 5, TimeUnit.SECONDS)
        try {
            socket.enabledProtocols = arrayOf("TLSv1.3"); socket.needClientAuth = true
            socket.tcpNoDelay = true; socket.soTimeout = 5_000; socket.startHandshake()
            tlsAuthenticated = true
            validatePeerRoute(requireNotNull(selectedInterface), socket.inetAddress)
            val request = GatewayLaneRequest.decode(ByteArray(GatewayLaneRequest.SIZE).also { DataInputStream(socket.inputStream).readFully(it) })
            val enrollment = requireNotNull(offer)
            require(request.pairingID == enrollment.pairingID && request.roomID == enrollment.roomID && operation.get() == attempt)
            if (request.lane == GatewayLane.HUB_CONTROL) {
                val accepted = synchronized(this) {
                    check(operation.get() == attempt && offer?.pairingID == enrollment.pairingID) { "Hub control claim belongs to a replaced enrollment" }
                    if (!associationAuthenticated) enrollment.validate(clock())
                    if (control != null) false else { recordRoute(socket); control = socket; true }
                }
                if (!accepted) { socket.outputStream.write(2); socket.outputStream.flush(); return }
                socket.outputStream.write(0); socket.outputStream.flush()
                deadline.cancel(false)
                pendingHandshake.release(); handshakeReleased = true
                socket.soTimeout = GatewayProtocol.HEARTBEAT_TIMEOUT_MILLISECONDS
                val generation = (SecureRandom().nextLong() and Long.MAX_VALUE).coerceAtLeast(1)
                while (operation.get() == attempt && control === socket) {
                    val current = requireNotNull(guideDescriptor?.invoke()) { "Guide tour ended" }.copy(generation = generation)
                    current.validate(enrollment)
                    synchronized(this) {
                        check(operation.get() == attempt && control === socket) { "Guide descriptor belongs to a replaced USB association" }
                        descriptor = current
                    }
                    val bytes = current.encode()
                    val deadline = timer.schedule({ socket.close() }, 3, TimeUnit.SECONDS)
                    try {
                        DataOutputStream(socket.outputStream).apply { writeShort(bytes.size); write(bytes); flush() }
                        check(socket.inputStream.read() == 0) { "Companion heartbeat acknowledgement failed" }
                        synchronized(this) {
                            check(operation.get() == attempt && control === socket)
                            associationAuthenticated = true; onConnected?.invoke(true)
                        }
                    }
                    finally { deadline.cancel(false) }
                    // Dedicated worker only; UI/control cancellation never waits on heartbeat.
                    TimeUnit.MILLISECONDS.sleep(GatewayProtocol.HEARTBEAT_MILLISECONDS)
                }
            } else {
                val active = requireNotNull(descriptor)
                require(isConnected && request.generation == active.generation)
                lease = if (request.lane == GatewayLane.ADMISSION) pendingAdmission else persistent
                if (!lease.tryAcquire()) { lease = null; socket.outputStream.write(2); return }
                val local = Socket()
                pendingLocal.set(local)
                sockets.add(local)
                val lane = com.aessam.toursession.NearbyLaneRequest.Lane.entries.single { it.localPort == request.lane.localPort }
                try {
                    check(!timedOut.get()) { "Gateway handshake deadline expired" }
                    local.tcpNoDelay = true
                    local.connect(InetSocketAddress("127.0.0.1", requireNotNull(request.lane.localPort)), 5_000)
                    ingress.forwardConnected(NearbyTCPConnection(socket), NearbyTCPConnection(local), lane) {
                        socket.outputStream.write(0); socket.outputStream.flush(); socket.soTimeout = 0
                        deadline.cancel(false)
                        pendingHandshake.release(); handshakeReleased = true
                    }
                }
                finally { sockets.remove(local); local.close() }
            }
        } catch (error: Exception) {
            if (operation.get() == attempt) {
                if (tlsAuthenticated && !handshakeReleased && !timedOut.get()) try {
                    socket.outputStream.write(if (error is NearbyLaneCapacityException) 2 else 1); socket.outputStream.flush()
                }
                catch (replyError: Exception) { Log.w("WiredHub", "Lane rejection reply failed (${replyError.javaClass.simpleName})") }
                if (control === socket) synchronized(this) { if (operation.get() == attempt && control === socket) fail(error) }
                else {
                    val count = rejectedConnections.updateAndGet { (it + 1).coerceAtMost(Long.MAX_VALUE - 1) }
                    // A leaf or an untrusted handshake cannot change healthy hub state.
                    // Log a bounded sample while retaining a counter for diagnosis.
                    if (count <= 8 || count and (count - 1) == 0L)
                        Log.w("WiredHub", "Rejected or closed leaf connection #$count (${error.javaClass.simpleName})")
                }
            }
        }
        finally {
            deadline.cancel(false)
            if (!handshakeReleased) pendingHandshake.release()
            lease?.release(); sockets.remove(socket)
            try { socket.close() } catch (error: Exception) { Log.w("WiredHub", "Socket close failed (${error.javaClass.simpleName})") }
            synchronized(this) { if (control === socket && operation.get() == attempt) disconnect() }
        }
    }

    @Synchronized private fun disconnect() {
        control = null; descriptor = null
        ingress.stop()
        sockets.filter { it !== server }.forEach { value ->
            try { value.close() } catch (error: Exception) { Log.w("WiredHub", "Connection close failed (${error.javaClass.simpleName})") }
            sockets.remove(value)
        }
        onDescriptor?.invoke(null); onConnected?.invoke(false)
    }
    @Synchronized override fun stop() {
        recoveryTask?.cancel(false); recoveryTask = null; discovery.stop()
        operation.incrementAndGet(); disconnect()
        connectingControl = false
        server?.close(); server = null; sockets.clear()
        offer = null; response = null; context = null; selectedInterface = null; guideDescriptor = null; lastRoute = null
        enrolledInterfaceName = null; enrolledAddressSize = 0; peerHost = null; nextReconnectAt = 0; reconnectFailures = 0; associationAuthenticated = false
    }
    override fun close() { stop(); (discovery as? Closeable)?.close(); ingress.close(); io.shutdownNow(); timer.shutdownNow(); recoveryMonitor.shutdownNow() }

    @Synchronized private fun startRecovery() {
        if (!enableAddressRecovery || recoveryTask != null) return
        val local = requireNotNull(selectedInterface)
        discovery.configure(requireNotNull(offer).pairingID, local, guideDescriptor != null)
        recoveryTask = recoveryMonitor.scheduleWithFixedDelay({
            try { refreshRecovery() } catch (error: Exception) { Log.w("WiredHub", "Wired recovery inspection failed (${error.javaClass.simpleName})") }
        }, 1, 1, TimeUnit.SECONDS)
    }

    /** Keeps confirmed trust immutable; only the untrusted endpoint and socket generation change. */
    @Synchronized private fun refreshRecovery() {
        if (recoveryTask == null || offer == null) return
        if (!associationAuthenticated && (System.nanoTime() - enrollmentStartedAt >=
            TimeUnit.MILLISECONDS.toNanos(GatewayProtocol.ENROLLMENT_LIFETIME_MILLISECONDS) ||
            (guideDescriptor != null && clock() >= requireNotNull(offer).expiresAtMilliseconds))) {
            stop(); onError?.invoke("Incomplete companion enrollment expired. Scan a new QR."); return
        }
        val current = selectRecoveryAddress(requireNotNull(enrolledInterfaceName), enrolledAddressSize, selectedInterface, availableInterfaces())
        if (current != selectedInterface) {
            operation.incrementAndGet()
            disconnect(); connectingControl = false
            server?.close(); server = null
            discovery.stop(); selectedInterface = current; nextReconnectAt = 0; reconnectFailures = 0
            if (current != null) {
                if (guideDescriptor != null) listenForConfirmedCompanion()
                else peerHost = null // Wait for exact paired-instance discovery on the new subnet.
                discovery.configure(requireNotNull(offer).pairingID, current, guideDescriptor != null)
            }
        }
        if (current != null && guideDescriptor != null && server == null) listenForConfirmedCompanion()
        if (current != null && guideDescriptor == null && peerHost != null && !isConnected && !connectingControl &&
            reconnectFailures < 5 && System.nanoTime() >= nextReconnectAt) {
            nextReconnectAt = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            startCompanionAttempt(resetBudget = false)
        }
    }
    private fun fail(error: Exception) {
        Log.w("WiredHub", "Wired companion failed (${error.javaClass.simpleName})")
        onError?.invoke(error.message ?: "Wired companion failed")
    }
    companion object {
        internal fun selectRecoveryAddress(name: String, addressBytes: Int, previous: WiredInterfaceAddress?, available: List<WiredInterfaceAddress>): WiredInterfaceAddress? {
            val candidates = available.filter { it.interfaceName == name && it.prefixLength > 0 &&
                it.prefixLength <= it.address.address.size * 8 }
            candidates.firstOrNull { it == previous }?.let { return it }
            val preferred = candidates.filter { it.address.address.size == addressBytes }
            return if (preferred.isNotEmpty()) preferred.singleOrNull() else candidates.singleOrNull()
        }
        internal fun requireUnambiguousPeer(local: WiredInterfaceAddress, peer: InetAddress, interfaces: List<WiredInterfaceAddress>) {
            require(local.contains(peer)) { "Remote peer is not on the selected wired subnet" }
            // An IPv6 link-local address explicitly scoped to the selected NIC cannot use another NIC's fe80 prefix.
            if (peer is Inet6Address && peer.isLinkLocalAddress && peer.scopeId > 0) {
                check(peer.scopeId == NetworkInterface.getByName(local.interfaceName)?.index) { "Peer IPv6 scope does not match selected USB interface" }
                return
            }
            require(interfaces.none { it.interfaceName != local.interfaceName && it.prefixLength >= local.prefixLength && it.contains(peer) }) {
                "Ambiguous route: another active interface covers the wired peer"
            }
        }
        private fun validatePeerRoute(local: WiredInterfaceAddress, peer: InetAddress) {
            val interfaces = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp }.flatMap { nic ->
                nic.interfaceAddresses.map { WiredInterfaceAddress(nic.name, it.address, it.networkPrefixLength) }
            }
            requireUnambiguousPeer(local, peer, interfaces)
        }
        internal fun numericAddress(host: String, local: WiredInterfaceAddress? = null): InetAddress {
            require(host.isNotEmpty() && host.none { it.isWhitespace() || it.isISOControl() })
            if (!host.contains(':')) require(host.split('.').size == 4 && host.split('.').all {
                it.isNotEmpty() && it.all(Char::isDigit) && it.toIntOrNull() in 0..255
            }) { "Wired peer must be a numeric address, never a DNS name" }
            else {
                require(host.count { it == '%' } <= 1)
                require(host.substringBefore('%').all { it in '0'..'9' || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' })
                if ('%' in host) require(host.substringAfter('%').isNotEmpty() && host.substringAfter('%').all {
                    it.isLetterOrDigit() || it == '_' || it == '-' || it == '.'
                })
            }
            // The sender's enX/scope index has no meaning on this phone. Parse only
            // the numeric bytes and scope link-local peers to our selected USB NIC.
            val numeric = InetAddress.getByName(host.substringBefore('%'))
            if (numeric is Inet6Address && numeric.isLinkLocalAddress && local != null) {
                val nic = requireNotNull(NetworkInterface.getByName(local.interfaceName)) { "Selected USB interface disappeared" }
                return Inet6Address.getByAddress(null, numeric.address, nic.index)
            }
            return numeric
        }
        private fun validateInterface(address: WiredInterfaceAddress) {
            val nic = requireNotNull(NetworkInterface.getByName(address.interfaceName)) { "USB interface disappeared" }
            check(nic.isUp && nic.inetAddresses.toList().contains(address.address)) { "USB address changed" }
        }
    }
}
