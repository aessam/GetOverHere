package com.aessam.comeoverhere.service

import android.content.Context
import android.os.Build
import android.util.Log
import com.aessam.comeoverhere.core.GatewayWiredInterface
import com.aessam.comeoverhere.core.NearbyAwareState
import com.aessam.comeoverhere.core.WiFiAwareRoomTransport
import com.aessam.comeoverhere.core.WiredCompanionTransport
import com.aessam.comeoverhere.core.WiredInterfaceAddress
import com.aessam.toursession.GatewayPairingMessage
import com.aessam.toursession.GatewayPairingRole
import com.aessam.toursession.GatewayRoomDescriptor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class GatewayRole { NONE, GUIDE, COMPANION }
enum class GatewayState { IDLE, OFFER, RESPONSE, AWAITING_CONFIRMATION, CONNECTING, CONNECTED, FAILED }
data class GatewayStatus(val role: GatewayRole = GatewayRole.NONE, val state: GatewayState = GatewayState.IDLE,
    val enrollmentQR: String? = null, val roomName: String? = null, val route: String? = null,
    val error: String? = null, val keepAwake: Boolean = false, val branchError: String? = null)

/** The application owns this service; UI and debug controls invoke these same operations. */
class GatewaySessionCoordinator internal constructor(private val tour: GatewayTourContext, private val scope: CoroutineScope,
    private val wired: GatewayWiredInterface, private val aware: GatewayBranchInterface?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val now: () -> Long = System::currentTimeMillis,
    private val findInterfaces: () -> List<WiredInterfaceAddress> = WiredInterfaceAddress::available) {
    constructor(context: Context, channels: ChannelService, scope: CoroutineScope) : this(context, channels, scope, WiredCompanionTransport())
    private constructor(context: Context, channels: ChannelService, scope: CoroutineScope, native: WiredCompanionTransport) :
        this(AppGatewayTourContext(channels), scope, native, if (Build.VERSION.SDK_INT >= 34)
            AwareGatewayBranch(WiFiAwareRoomTransport(context, guideLaneConnector = native)) else null)
    private val mutableStatus = MutableStateFlow(GatewayStatus())
    val status = mutableStatus.asStateFlow()
    private val mutableAddresses = MutableStateFlow<List<WiredInterfaceAddress>>(emptyList())
    val addresses = mutableAddresses.asStateFlow()
    val awareState = combine(status, aware?.state ?: MutableStateFlow(NearbyAwareState()), tour.guideAwareState) {
        current, companion, guide -> if (current.role == GatewayRole.GUIDE) guide else companion
    }.stateIn(scope, SharingStarted.Eagerly, NearbyAwareState())
    fun wiredRouteSnapshot(): com.aessam.comeoverhere.core.WiredRouteDiagnostic? = wired.routeSnapshot()
    fun awareRouteSnapshot(): com.aessam.comeoverhere.core.NearbyAwareDiagnostics = awareState.value.diagnostics
    private var scannedResponse: GatewayPairingMessage? = null
    @Volatile private var activeDescriptor: GatewayRoomDescriptor? = null
    fun activeRoomID(): String? = if (mutableStatus.value.role == GatewayRole.COMPANION)
        activeDescriptor?.record?.roomID?.toString() else tour.activeRoomID
    private var previousRecord: ByteArray? = null
    private var revision = 0L
    @Volatile private var generation = 0L
    private val operationMutex = Mutex()
    private var reconnectJob: Job? = null
    private var expiryJob: Job? = null
    private var pendingStop: Job? = null
    private var authenticatedOnce = false
    private var branchGeneration: Long? = null

    init {
        tour.setCompanionGuard { mutableStatus.value.role == GatewayRole.COMPANION }
        wired.onDescriptor = { descriptor -> val callbackGeneration = generation; scope.launch {
            if (generation != callbackGeneration) return@launch
            if (mutableStatus.value.role == GatewayRole.COMPANION) {
                activeDescriptor = descriptor
                if (descriptor == null) {
                    aware?.stop(); branchGeneration = null
                    mutableStatus.value = mutableStatus.value.copy(state = GatewayState.FAILED,
                        error = "Wired guide disconnected. Existing local guide listeners are unaffected.")
                    scheduleReconnect()
                } else {
                    aware?.publish(descriptor.record)
                    if (branchGeneration != descriptor.generation) {
                        branchGeneration = descriptor.generation
                        aware?.start()
                    }
                    mutableStatus.value = mutableStatus.value.copy(roomName = descriptor.record.name, route = wired.routeDescription,
                        state = GatewayState.CONNECTED, enrollmentQR = null, error = null)
                    authenticatedOnce = true
                    expiryJob?.cancel(); expiryJob = null
                    reconnectJob?.cancel(); reconnectJob = null
                }
            }
        } }
        wired.onConnected = { connected -> val callbackGeneration = generation; scope.launch {
            if (generation != callbackGeneration) return@launch
            if (mutableStatus.value.role == GatewayRole.GUIDE) {
                if (connected) { authenticatedOnce = true; expiryJob?.cancel(); expiryJob = null }
                mutableStatus.value = mutableStatus.value.copy(
                    state = if (connected) GatewayState.CONNECTED else GatewayState.CONNECTING,
                    route = wired.routeDescription, enrollmentQR = if (connected) null else mutableStatus.value.enrollmentQR)
            }
        } }
        wired.onError = { message -> val callbackGeneration = generation; scope.launch {
            if (generation == callbackGeneration) report(message)
        } }
        aware?.onError = { message -> val callbackGeneration = generation; scope.launch {
            if (generation == callbackGeneration && mutableStatus.value.role == GatewayRole.COMPANION)
                mutableStatus.value = mutableStatus.value.copy(branchError = message)
        } }
        scope.launch { tour.listenState.collect { state ->
            if (state != ListenState.BROADCASTING) {
                tour.endGuideDiscovery()
                if (mutableStatus.value.role == GatewayRole.GUIDE) {
                    stop(); report("The guide tour ended; its companion association was removed.")
                }
            }
        } }
    }

    fun refreshInterfaces() = scope.launch {
        try { mutableAddresses.value = withContext(ioDispatcher) { findInterfaces() } }
        catch (error: Exception) { report(error.message ?: "Wired interface inspection failed") }
    }

    fun beginGuide(address: WiredInterfaceAddress) = perform {
        check(mutableStatus.value.role == GatewayRole.NONE) { "Remove the current companion association first" }
        val source = requireNotNull(tour.descriptor()) { "Create a tour on this phone first" }
        previousRecord = null; revision = 0
        val token = wired.makeOffer(source.record, source.guidePublicKey, address, ::currentDescriptor)
        GatewayStatus(GatewayRole.GUIDE, GatewayState.OFFER, token.qrText(), source.record.name, address.displayName)
    }

    fun scanEnrollment(text: String, address: WiredInterfaceAddress?) = perform {
        val message = GatewayPairingMessage.fromQR(text)
        message.validate(now())
        when (message.role) {
            GatewayPairingRole.OFFER -> {
                check(tour.listenState.value == ListenState.IDLE && mutableStatus.value.role == GatewayRole.NONE) { "Leave the active tour or association first" }
                check(aware != null) { "Android companion requires the supported Wi-Fi Aware implementation (Android 14+)" }
                val reply = wired.answerOffer(message, requireNotNull(address) { "Select the USB interface first" })
                GatewayStatus(GatewayRole.COMPANION, GatewayState.RESPONSE, reply.qrText(),
                    route = address.displayName, keepAwake = true)
            }
            GatewayPairingRole.RESPONSE -> {
                check(mutableStatus.value.role == GatewayRole.GUIDE && mutableStatus.value.state == GatewayState.OFFER)
                scannedResponse = message
                mutableStatus.value.copy(state = GatewayState.AWAITING_CONFIRMATION)
            }
        }
    }

    fun confirmCompanion() = perform {
        wired.confirmResponse(requireNotNull(scannedResponse) { "Scan the companion response first" })
        mutableStatus.value.copy(state = GatewayState.CONNECTING, enrollmentQR = null, error = null)
    }

    fun connectCompanion() = perform {
        check(mutableStatus.value.role == GatewayRole.COMPANION)
        wired.startCompanion()
        mutableStatus.value.copy(state = GatewayState.CONNECTING, error = null)
    }

    fun setKeepAwake(value: Boolean) {
        if (mutableStatus.value.role == GatewayRole.COMPANION) mutableStatus.value = mutableStatus.value.copy(keepAwake = value)
    }

    fun retryAndroidBranch() {
        check(mutableStatus.value.role == GatewayRole.COMPANION && wired.isConnected) { "Connect the wired guide first" }
        val current = requireNotNull(activeDescriptor)
        mutableStatus.value = mutableStatus.value.copy(branchError = null)
        aware?.stop(); aware?.publish(current.record); aware?.start()
    }

    fun stop() {
        generation++
        reconnectJob?.cancel(); reconnectJob = null; expiryJob?.cancel(); expiryJob = null
        aware?.stop(); scannedResponse = null; previousRecord = null; revision = 0; activeDescriptor = null
        if (mutableStatus.value.role == GatewayRole.COMPANION) tour.resumeDiscovery()
        authenticatedOnce = false; branchGeneration = null
        mutableStatus.value = GatewayStatus()
        pendingStop = scope.launch(ioDispatcher) { operationMutex.withLock { wired.stop() } }
    }

    @Synchronized private fun currentDescriptor(): GatewayRoomDescriptor? {
        val source = tour.descriptor() ?: return null
        val bytes = source.record.encode()
        if (previousRecord?.contentEquals(bytes) != true) { previousRecord = bytes; revision++ }
        return source.copy(recordRevision = revision)
    }

    private fun perform(action: suspend () -> GatewayStatus) = scope.launch {
        val attempt = generation
        try {
            pendingStop?.join()
            val result = withContext(ioDispatcher) { operationMutex.withLock {
                if (generation != attempt) return@withLock null
                val value = action()
                if (generation != attempt) { wired.stop(); null } else value
            } }
            if (result != null && generation == attempt) {
                val previousRole = mutableStatus.value.role
                try {
                    if (result.role == GatewayRole.GUIDE && previousRole != GatewayRole.GUIDE) {
                        val selectedRoom = GatewayPairingMessage.fromQR(requireNotNull(result.enrollmentQR)).roomID.toString()
                        check(tour.listenState.value == ListenState.BROADCASTING && tour.activeRoomID == selectedRoom) {
                            "The selected guide tour ended or changed during companion setup"
                        }
                        tour.enableGuideDiscovery()
                    }
                    if (result.role == GatewayRole.COMPANION && previousRole != GatewayRole.COMPANION) tour.suspendDiscovery()
                } catch (error: Exception) {
                    tour.resumeDiscovery(); tour.endGuideDiscovery(); stop()
                    report(error.message ?: "Gateway discovery could not start")
                    return@launch
                }
                mutableStatus.value = if (authenticatedOnce && wired.isConnected)
                    result.copy(state = GatewayState.CONNECTED, enrollmentQR = null,
                        roomName = activeDescriptor?.record?.name ?: result.roomName,
                        route = wired.routeDescription, branchError = mutableStatus.value.branchError) else result
                result.enrollmentQR?.let { qr ->
                    if (expiryJob == null) expiryJob = scope.launch {
                        val expiry = GatewayPairingMessage.fromQR(qr).expiresAtMilliseconds
                        delay((expiry - now()).coerceAtLeast(0))
                        if (generation == attempt && !authenticatedOnce) {
                            stop(); report("Incomplete companion enrollment expired. Start again.")
                        }
                    }
                }
            }
        }
        catch (error: Exception) { if (generation == attempt) report(error.message ?: "Companion operation failed") }
    }
    private fun scheduleReconnect() {
        if (wired.automaticRecoveryEnabled) return // Native owner tracks this paired instance on its selected USB NIC.
        if (reconnectJob?.isActive == true || mutableStatus.value.enrollmentQR != null) return
        val attempt = generation
        reconnectJob = scope.launch {
            for (wait in listOf(500L, 1_000L, 2_000L, 3_000L, 5_000L)) {
                delay(wait)
                if (generation != attempt || mutableStatus.value.role != GatewayRole.COMPANION || wired.isConnected) return@launch
                connectCompanion().join()
            }
            report("Wired reconnect attempts exhausted. Check USB, then reconnect or enroll again if the address changed.")
        }
    }
    private fun report(message: String) {
        Log.w("GatewaySession", "Companion session operation failed")
        mutableStatus.value = mutableStatus.value.copy(error = message)
    }
}
