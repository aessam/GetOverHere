package com.aessam.comeoverhere.debug

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.aessam.comeoverhere.ComeOverHereApp
import com.aessam.comeoverhere.core.HubIdentity
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.service.GatewayRole
import com.aessam.comeoverhere.service.ListenState
import com.aessam.comeoverhere.service.SessionConnectionState
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject

/** Debug-source-set only. Visible consent activates a bounded localhost TLS/HMAC endpoint. */
internal class GatewayDebugControl(
    private val app: ComeOverHereApp,
    private val closeListener: (SSLServerSocket) -> Unit = { it.close() },
    private val beforePublication: (SSLServerSocket) -> Unit = {},
) {
    private val key = ByteArray(32).also(SecureRandom()::nextBytes)
    private val seen = HashSet<UUID>()
    private val clients = ConcurrentHashMap.newKeySet<SSLSocket>()
    private val slots = Semaphore(4)
    private val acceptor = Executors.newSingleThreadExecutor()
    private val workers = Executors.newFixedThreadPool(4)
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val resumed = AtomicInteger()
    private val expires = SystemClock.elapsedRealtime() + LIFETIME_MS
    private val credentials = File(app.filesDir, "debug-control/credentials.json")
    @Volatile private var listener: SSLServerSocket? = null
    @Volatile private var stopped = false
    val active: Boolean get() = !stopped && listener != null && SystemClock.elapsedRealtime() < expires

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) { resumed.incrementAndGet() }
        override fun onActivityPaused(activity: Activity) { resumed.decrementAndGet() }
        override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    init {
        // Constructed on the visible consent activity's Enable click. Register
        // before async TLS startup so a Home/lock event cannot be missed.
        resumed.set(1)
        app.registerActivityLifecycleCallbacks(lifecycle)
    }

    /** Called while the consent activity is resumed, after the Enable button. */
    fun start() {
        check(Build.VERSION.SDK_INT >= 29) { "Debug TLS 1.3 requires Android 10" }
        check(listener == null && !stopped)
        val identity = HubIdentity("goh.debug.control.v1")
        val server = (identity.context(ByteArray(32)).serverSocketFactory.createServerSocket() as SSLServerSocket).apply {
            enabledProtocols = arrayOf("TLSv1.3")
            needClientAuth = false // The fresh application HMAC key authenticates the controller.
            bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 4)
        }
        val temporary = File(credentials.parentFile, "credentials.tmp")
        try {
            beforePublication(server)
            check(credentials.parentFile?.let { it.isDirectory || it.mkdirs() } == true)
            // Native identity creation and file contents stay off the publication
            // lock. Stop never waits for KeyStore/TLS or a credential file write.
            temporary.writeText(JSONObject().put("schema", 1).put("port", server.localPort)
                .put("key", Base64.encodeToString(key, Base64.NO_WRAP))
                .put("certificate_sha256", identity.fingerprint.joinToString("") { "%02x".format(it) })
                .put("expires_at_ms", System.currentTimeMillis() + LIFETIME_MS).toString())
            synchronized(this) {
                check(!stopped) { "Debug activation stopped before publication" }
                listener = server
                // Only the atomic same-directory rename is inside the short
                // publication critical section, alongside executor submission.
                check(temporary.renameTo(credentials)) { "Could not store debug credentials" }
                timer.schedule({ stop() }, LIFETIME_MS, TimeUnit.MILLISECONDS)
                acceptor.execute {
                    try {
                        while (active) {
                            val client = server.accept() as SSLSocket
                            if (!slots.tryAcquire()) { client.close(); continue }
                            clients.add(client)
                            workers.execute { handle(client) }
                        }
                    } catch (error: Exception) {
                        if (!stopped) { Log.w(TAG, "Debug listener failed: ${error.javaClass.simpleName}"); stop() }
                    }
                }
            }
        } catch (error: Exception) {
            // Stop may already have run while native creation/file IO was in
            // flight. Idempotent stop cannot own a listener created after it.
            try { server.close() } catch (closeError: Exception) { Log.w(TAG, "Unpublished debug listener cleanup: ${closeError.javaClass.simpleName}") }
            try {
                if (temporary.exists() && !temporary.delete()) Log.w(TAG, "Could not remove unpublished debug credentials")
            } catch (cleanupError: Exception) { Log.w(TAG, "Unpublished debug credential cleanup: ${cleanupError.javaClass.simpleName}") }
            stop()
            throw error
        }
    }

    @Synchronized fun stop() {
        if (stopped) return
        stopped = true
        // Each cleanup is independent. An IOException closing a native socket
        // must not keep credentials, key bytes, lifecycle callbacks or workers.
        fun cleanup(label: String, action: () -> Unit) {
            try { action() } catch (error: Exception) { Log.w(TAG, "Debug $label cleanup: ${error.javaClass.simpleName}") }
        }
        key.fill(0); seen.clear()
        cleanup("credentials") {
            if (credentials.exists() && !credentials.delete()) Log.w(TAG, "Could not remove expired debug credentials")
            val temporary = File(credentials.parentFile, "credentials.tmp")
            if (temporary.exists() && !temporary.delete()) Log.w(TAG, "Could not remove partial debug credentials")
        }
        cleanup("lifecycle") { app.unregisterActivityLifecycleCallbacks(lifecycle) }
        val oldListener = listener; listener = null
        cleanup("listener") { oldListener?.let(closeListener) }
        clients.forEach { client ->
            try { client.close() } catch (error: Exception) { Log.w(TAG, "Debug client cleanup: ${error.javaClass.simpleName}") }
        }
        clients.clear()
        cleanup("acceptor") { acceptor.shutdownNow() }
        cleanup("workers") { workers.shutdownNow() }
        cleanup("timer") { timer.shutdownNow() }
    }

    private fun handle(client: SSLSocket) {
        val deadline = try {
            timer.schedule({
                try { client.close() } catch (error: Exception) { Log.w(TAG, "Debug deadline cleanup: ${error.javaClass.simpleName}") }
            }, 10, TimeUnit.SECONDS)
        } catch (error: RejectedExecutionException) {
            clients.remove(client); slots.release()
            try { client.close() } catch (closeError: Exception) { Log.w(TAG, "Expired debug cleanup: ${closeError.javaClass.simpleName}") }
            return
        }
        try {
            client.use { socket ->
                socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = 5_000; socket.startHandshake()
                val input = DataInputStream(socket.inputStream)
                val length = input.readInt()
                require(length in 1..MAX_FRAME)
                val outer = ByteArray(length).also(input::readFully).toString(Charsets.UTF_8)
                requireFlatObject(outer)
                val envelope = JSONObject(outer)
                require(envelope.keys().asSequence().toSet() == setOf("payload", "mac"))
                require(envelope.get("payload") is String && envelope.get("mac") is String)
                val payload = Base64.decode(envelope.getString("payload"), Base64.NO_WRAP)
                val suppliedMac = Base64.decode(envelope.getString("mac"), Base64.NO_WRAP)
                val request = authenticate(payload, suppliedMac)
                val id = request.getString("id")
                val response = try {
                    val result = runBlocking { withTimeout(8_000) { withContext(Dispatchers.Main) {
                        check(active) { "Debug activation expired" }
                        execute(request)
                    } } }
                    JSONObject().put("id", id).put("success", true).put("result", result.toString())
                } catch (error: Exception) {
                    Log.w(TAG, "Debug command rejected: ${error.javaClass.simpleName}")
                    JSONObject().put("id", id).put("success", false).put("result", "Command rejected; check arguments, permissions and app state")
                }
                val bytes = response.toString().toByteArray()
                check(bytes.size in 1..MAX_FRAME)
                DataOutputStream(socket.outputStream).apply { writeInt(bytes.size); write(bytes); flush() }
            }
        } catch (error: Exception) {
            // No secrets, requests, room codes, frames or enrollment text in logs.
            Log.w(TAG, "Debug connection rejected: ${error.javaClass.simpleName}")
        } finally {
            deadline.cancel(false); clients.remove(client); slots.release()
        }
    }

    @Synchronized private fun authenticate(payload: ByteArray, suppliedMac: ByteArray): JSONObject {
        check(active && payload.size in 1..MAX_FRAME && suppliedMac.size == 32)
        val computed = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(payload)
        require(MessageDigest.isEqual(computed, suppliedMac))
        val request = JSONObject(payload.toString(Charsets.UTF_8))
        require(request.keys().asSequence().toSet() == setOf("id", "command", "arguments"))
        val id = UUID.fromString(request.getString("id"))
        check(seen.size < 2048 && seen.add(id)) { "Replayed request or activation budget exhausted" }
        return request
    }

    private fun requireFlatObject(text: String) {
        // Reject recursive objects/arrays before parsing unauthenticated JSON.
        var quoted = false
        var escaped = false
        var depth = 0
        for (character in text) {
            if (quoted) {
                if (escaped) escaped = false
                else if (character == '\\') escaped = true
                else if (character == '"') quoted = false
            } else when (character) {
                '"' -> quoted = true
                '{' -> { depth++; require(depth == 1) }
                '}' -> { depth--; require(depth == 0) }
                '[', ']' -> error("Nested debug envelope rejected")
            }
        }
        require(!quoted && !escaped && depth == 0)
    }

    private suspend fun execute(request: JSONObject): JSONObject {
        val command = request.getString("command")
        val args = request.getJSONObject("arguments")
        val permitted = ARGUMENTS[command] ?: error("Unknown debug command")
        require(args.keys().asSequence().all { it in permitted && args.get(it) is String && args.getString(it).toByteArray().size <= 570 })
        if (command !in setOf("status", "gateway-status", "scenario-status")) check(resumed.get() > 0) { "Bring the app to foreground" }
        fun argument(name: String) = args.getString(name).also { require(it.isNotEmpty()) }
        fun boolean(name: String): Boolean = when (argument(name)) { "true" -> true; "false" -> false; else -> error("Invalid boolean") }
        val channels = app.channelService
        val gateway = app.gateway
        fun idle() = check(channels.activeChannelID.value == null && channels.connectionState.value != SessionConnectionState.CONNECTING)
        fun guide() = check(channels.listenState.value == ListenState.BROADCASTING)
        suspend fun address() = run {
            gateway.refreshInterfaces().join()
            val values = gateway.addresses.value
            val requested = args.optString("interface", "")
            if (requested.isEmpty()) values.singleOrNull() ?: error("Choose an explicit wired interface")
            else values.singleOrNull { it.displayName == requested } ?: error("Wired interface unavailable")
        }
        when (command) {
            "status", "gateway-status" -> Unit
            "scenario-start" -> return GatewayScenarioRecorder.start(app, argument("seconds").toInt(), args.optString("runID", UUID.randomUUID().toString()))
            "scenario-status" -> return GatewayScenarioRecorder.status()
            "scenario-cancel" -> { GatewayScenarioRecorder.cancel(); return GatewayScenarioRecorder.status() }
            "gateway-begin" -> gateway.beginGuide(address()).join()
            "gateway-pair" -> gateway.scanEnrollment(argument("code"), if (gateway.status.value.role == GatewayRole.GUIDE) null else address()).join()
            "gateway-confirm" -> gateway.confirmCompanion().join()
            "gateway-connect" -> gateway.connectCompanion().join()
            "gateway-stop" -> gateway.stop()
            "strict-aware" -> { idle(); channels.setStrictAwareOnly(boolean("enabled")) }
            "discover" -> { idle(); channels.setBluetoothDiscoveryEnabled(true); channels.awareSettings?.setEnabled(true) }
            "create" -> {
                idle(); check(gateway.status.value.role != GatewayRole.COMPANION)
                check(app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                val name = argument("name").trim(); require(name.isNotEmpty() && name.toByteArray().size <= 120)
                channels.createChannel(name)
            }
            "join" -> {
                idle(); check(gateway.status.value.role != GatewayRole.COMPANION)
                val room = channels.channels.value.singleOrNull { it.id == argument("id") } ?: error("Room unavailable")
                check(channels.canJoin(room)); channels.joinChannel(room, args.optString("code", ""))
            }
            "leave" -> channels.leaveChannel()
            "room-lock" -> { guide(); channels.updateRoomAccess(boolean("locked"), args.optString("code", "")) }
            "next-slide" -> { guide(); channels.nextSlide() }
            "previous-slide" -> { guide(); channels.previousSlide() }
            "retry-audio" -> channels.retryAudio()
            "restart-microphone" -> { guide(); channels.restartMicrophone() }
            "output" -> channels.setListenerOutput(when (argument("mode")) { "speaker" -> ListenerOutput.SPEAKER; "privateAudio" -> ListenerOutput.PRIVATE_AUDIO; else -> error("Unknown output") })
        }
        if (command.startsWith("gateway-") && command != "gateway-status") check(gateway.status.value.error == null)
        return snapshot()
    }

    private fun snapshot(): JSONObject {
        val channel = app.channelService
        val gateway = app.gateway.status.value
        val version = app.packageManager.getPackageInfo(app.packageName, 0)
        val wired = app.gateway.wiredRouteSnapshot()
        return JSONObject().put("deviceID", channel.localPeerID).put("platform", "android")
            .put("model", Build.MODEL).put("os", Build.VERSION.RELEASE).put("bundleBuild", version.versionCode)
            .put("sessionState", if (channel.activeChannelID.value == null && gateway.role == GatewayRole.NONE) "idle" else "active")
            .put("debuggerAttached", Debug.isDebuggerConnected()).put("debugKeepAwake", false)
            .put("foreground", resumed.get() > 0).put("activeRoom", channel.activeChannelID.value ?: "")
            .put("role", when (channel.listenState.value) { ListenState.BROADCASTING -> "guide"; ListenState.LISTENING -> "guest"; ListenState.IDLE -> "none" })
            .put("connection", channel.connectionState.value.name).put("audio", channel.audioRuntimeState.value.name)
            .put("audioReadyGuests", channel.audioReadyGuestCount.value).put("connectedGuests", channel.connectedGuestCount.value)
            .put("acceptedPlaybackBytes", app.audioEngine.acceptedPlaybackByteCount)
            .put("captureDroppedBuffers", app.audioEngine.captureDroppedBufferCount)
            .put("audioCapture", JSONObject(channel.captureDiagnostics()))
            .put("locked", channel.isRoomLocked.value).put("error", channel.audioRuntimeError.value ?: channel.tourFeatureError.value ?: "")
            .put("routes", JSONArray()).put("routeEvidence", "unqualified")
            .put("wiredRoute", wired?.let { route -> JSONObject().put("interface", route.interfaceName)
                .put("localAddress", route.localAddress).put("remoteAddress", route.remoteAddress)
                .put("localPort", route.localPort).put("remotePort", route.remotePort)
                .put("generation", route.generation ?: JSONObject.NULL).put("connected", route.connected)
                .put("selectedSourceMatches", route.selectedSourceMatches) } ?: JSONObject.NULL)
            .put("awareNetworks", JSONArray(app.gateway.awareRouteSnapshot().networks.map { network ->
                JSONObject().put("profile", network.profile.name).put("networkID", network.networkHandle)
                    .put("interface", network.interfaceName ?: JSONObject.NULL)
            }))
            .put("gateway", JSONObject().put("role", gateway.role.name.lowercase()).put("state", gateway.state.name.lowercase())
                .put("roomID", app.gateway.activeRoomID() ?: "").put("generation", wired?.generation ?: JSONObject.NULL)
                .put("pairingQR", gateway.enrollmentQR ?: "").put("room", gateway.roomName ?: "")
                .put("interface", gateway.route ?: "").put("error", gateway.error ?: "").put("keepAwake", gateway.keepAwake)
                .put("branchError", gateway.branchError ?: "")
                .put("availableInterfaces", JSONArray(app.gateway.addresses.value.map { it.displayName })))
            .put("rooms", JSONArray(channel.channels.value.take(64).map { room ->
                JSONObject().put("id", room.id).put("name", room.name).put("joinable", channel.canJoin(room))
            }))
    }

    companion object {
        private const val TAG = "GatewayDebugControl"
        private const val MAX_FRAME = 32_768
        private const val LIFETIME_MS = 600_000L
        private val ARGUMENTS = mapOf("status" to emptySet(), "gateway-status" to emptySet(),
            "scenario-start" to setOf("seconds", "runID"), "scenario-status" to emptySet(), "scenario-cancel" to emptySet(),
            "gateway-begin" to setOf("interface"), "gateway-pair" to setOf("code", "interface"),
            "gateway-confirm" to emptySet(), "gateway-connect" to emptySet(), "gateway-stop" to emptySet(),
            "strict-aware" to setOf("enabled"),
            "discover" to emptySet(), "create" to setOf("name"), "join" to setOf("id", "code"), "leave" to emptySet(),
            "room-lock" to setOf("locked", "code"), "next-slide" to emptySet(), "previous-slide" to emptySet(),
            "retry-audio" to emptySet(), "restart-microphone" to emptySet(), "output" to setOf("mode"))
    }
}
