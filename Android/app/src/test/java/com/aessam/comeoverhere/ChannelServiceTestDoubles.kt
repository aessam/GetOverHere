package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioPlane
import com.aessam.comeoverhere.core.RoomAdmissionInterface
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.ControlPlane
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.core.PeerEvent
import com.aessam.comeoverhere.core.PeerInfo
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionAssetTransport
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionControlTransport
import com.aessam.comeoverhere.service.AudioEngineInterface
import com.aessam.comeoverhere.service.LocalDevicePosition
import com.aessam.comeoverhere.service.LocalGuidanceInterface
import com.aessam.comeoverhere.service.LocalGuidanceStatus
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionMessageKind
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

class LifecycleRoomAdmission : RoomAdmissionInterface {
    var joinError: Exception? = null
    private val signers = mutableMapOf<UUID, com.aessam.toursession.GuideFrameSigner>()
    override fun start(sessionID: UUID, sessionCode: String, signer: com.aessam.toursession.GuideFrameSigner) = Unit
    override fun update(policy: RoomAccessPolicy) = Unit
    override fun stop() = Unit
    override fun join(host: String, sessionID: UUID, expectedGuideID: UUID, code: String?): com.aessam.toursession.AdmittedRoomCredentials {
        joinError?.let { throw it }
        val signer = signers.getOrPut(sessionID) { com.aessam.toursession.GuideFrameSigner(sessionID, expectedGuideID) }
        val guide = com.aessam.toursession.RoomAdmissionV2.Guide(sessionID, RoomAccessPolicy(sessionID, code), signer)
        val guest = com.aessam.toursession.RoomAdmissionV2.Guest(guide.challenge, sessionID, expectedGuideID, code)
        return guest.open(guide.reply(guest.request, "23456789AB"))
    }
}

/**
 * Shared ChannelService-level doubles (G4, DSCN-23). They record every lane call and expose `emit`
 * so a JVM test can drive the product state machine without sockets, NSD, or an AudioManager.
 * G5 reuses [LifecycleAssetTransport] for its transfer tests.
 */

internal class LifecycleControlPlane(
    override val localPeer: PeerInfo = PeerInfo(id = UUID.randomUUID().toString(), displayName = "Local"),
) : ControlPlane, com.aessam.comeoverhere.core.NearbyRouteControl {
    override var usesBluetoothGuestRoute = false
    override val awareSettings: com.aessam.comeoverhere.core.NearbyAwareSettings? = null
    var nearbyAvailable = false
    var nearbyStopCalls = 0
    var nearbyPrepareCalls = 0
    var nearbyPrepareError: Exception? = null
    var nearbyTransport = com.aessam.toursession.SessionTransportRoute.BLUETOOTH
    override var activeNearbyGuestRoute: com.aessam.comeoverhere.core.NearbyGuestRoute? = null
    override fun canConnectNearby(roomID: UUID) = nearbyAvailable
    override suspend fun prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID): com.aessam.comeoverhere.core.NearbyGuestRoute {
        check(nearbyAvailable)
        nearbyPrepareError?.let { throw it }
        nearbyPrepareCalls++; usesBluetoothGuestRoute = nearbyTransport == com.aessam.toursession.SessionTransportRoute.BLUETOOTH
        return activeNearbyGuestRoute ?: com.aessam.comeoverhere.core.NearbyGuestRoute(
            "127.0.0.1", nearbyTransport, roomID, UUID.randomUUID(),
        ).also { activeNearbyGuestRoute = it }
    }
    override fun stopNearbyGuest() { nearbyStopCalls++; usesBluetoothGuestRoute = false; activeNearbyGuestRoute = null }
    var bluetoothMode = com.aessam.comeoverhere.core.BluetoothDiscoveryMode.OFF
    override fun setBluetoothDiscoveryMode(mode: com.aessam.comeoverhere.core.BluetoothDiscoveryMode) { bluetoothMode = mode }
    private val mutableConnectedPeers = MutableStateFlow<List<PeerInfo>>(emptyList())
    override val connectedPeers: StateFlow<List<PeerInfo>> = mutableConnectedPeers.asStateFlow()
    private val mutableCommands = MutableSharedFlow<Pair<BLECommand, PeerInfo>>(extraBufferCapacity = 64)
    override val commands: SharedFlow<Pair<BLECommand, PeerInfo>> = mutableCommands.asSharedFlow()
    private val mutablePeerEvents = MutableSharedFlow<PeerEvent>(extraBufferCapacity = 64)
    override val peerEvents: SharedFlow<PeerEvent> = mutablePeerEvents.asSharedFlow()

    val broadcasts = CopyOnWriteArrayList<BLECommand>()
    var startCalls = 0
    var stopCalls = 0

    val announcedChannelIDs: List<String>
        get() = broadcasts.filterIsInstance<BLECommand.ChannelAnnounce>().map { it.channelID }
    val endedChannelIDs: List<String>
        get() = broadcasts.filterIsInstance<BLECommand.ChannelEnded>().map { it.channelID }

    override fun start() { startCalls += 1 }
    override fun stop() { stopCalls += 1 }
    override fun broadcast(command: BLECommand) { broadcasts += command }
    override fun send(command: BLECommand, to: PeerInfo) { broadcasts += command }

    /** Delivers a discovery command as if NSD had resolved it from [from]. */
    fun emit(
        command: BLECommand,
        from: PeerInfo = PeerInfo(displayName = "Guide", platform = PeerInfo.Platform.IOS),
    ) {
        check(mutableCommands.tryEmit(command to from)) { "command buffer is full" }
    }
}

internal class LifecycleAudioPlane : AudioPlane {
    var configuredAuthentication: com.aessam.comeoverhere.core.SessionGuideAuthentication? = null
    override fun configureGuideAuthentication(authentication: com.aessam.comeoverhere.core.SessionGuideAuthentication) { configuredAuthentication = authentication }
    override var isActive = false
    var startBroadcastingCalls = 0
    var startListeningCalls = 0
    var stopCalls = 0
    var clearSessionCalls = 0
    var configureCalls = 0
    val sent = CopyOnWriteArrayList<ByteArray>()
    var startBroadcastingError: Exception? = null
    private var handler: ((AudioSessionEvent) -> Unit)? = null
    private var onAudio: ((ByteArray) -> Unit)? = null

    override fun startBroadcasting(channelID: String, quality: AudioQuality) {
        startBroadcastingCalls += 1
        startBroadcastingError?.let { throw it }
        isActive = true
    }

    override fun sendAudio(data: ByteArray) { sent += data }

    override fun startListening(channelID: String, onAudio: (ByteArray) -> Unit) {
        startListeningCalls += 1
        isActive = true
        this.onAudio = onAudio
    }

    override fun stop() {
        stopCalls += 1
        isActive = false
    }

    override fun clearSession() {
        clearSessionCalls += 1
        isActive = false
    }

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {
        configureCalls += 1
    }

    override fun setSessionEventHandler(handler: ((AudioSessionEvent) -> Unit)?) {
        this.handler = handler
    }

    fun emit(event: AudioSessionEvent) {
        checkNotNull(handler) { "audio session handler is not installed" }.invoke(event)
    }
    fun capturedEventHandler(): (AudioSessionEvent) -> Unit = requireNotNull(handler)

    fun emitPCM(data: ByteArray) = checkNotNull(onAudio).invoke(data)
}

internal class LifecycleControlTransport : SessionControlTransport {
    var configuredAuthentication: com.aessam.comeoverhere.core.SessionGuideAuthentication? = null
    override fun configureGuideAuthentication(authentication: com.aessam.comeoverhere.core.SessionGuideAuthentication) { configuredAuthentication = authentication }
    var configureCalls = 0
    override var isActive = false
    override var hostIP: String? = null
    var startGuideCalls = 0
    var startGuestCalls = 0
    var stopCalls = 0
    var clearSessionCalls = 0
    val startGuestHostIPs = CopyOnWriteArrayList<String>()
    val sent = CopyOnWriteArrayList<Pair<SessionMessageKind, ByteArray>>()
    var startGuideError: Exception? = null
    /** Suspends [sendLeave] until completed, so a test can observe the state between End Tour and teardown. */
    var leaveGate: CompletableDeferred<Unit>? = null
    var leaveFlushCount = 0
    /** Set when the synchronous, main-thread-blocking LEAVE path was used. */
    var blockingLeaveUsed = false
    private var handler: ((SessionControlEvent) -> Unit)? = null

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) { configureCalls += 1 }

    override fun setEventHandler(handler: ((SessionControlEvent) -> Unit)?) {
        this.handler = handler
    }

    override fun startGuide() {
        startGuideCalls += 1
        startGuideError?.let { throw it }
        isActive = true
    }

    override fun startGuest() {
        startGuestCalls += 1
        startGuestHostIPs += hostIP ?: "<none>"
        isActive = true
    }

    override fun send(kind: SessionMessageKind, payload: ByteArray) {
        if (kind == SessionMessageKind.LEAVE) blockingLeaveUsed = true
        sent += kind to payload
    }

    override suspend fun sendLeave() {
        leaveFlushCount += 1
        leaveGate?.await()
        sent += SessionMessageKind.LEAVE to byteArrayOf()
    }

    override fun stop() {
        stopCalls += 1
        isActive = false
    }

    override fun clearSession() {
        clearSessionCalls += 1
        isActive = false
    }

    fun emit(event: SessionControlEvent) {
        checkNotNull(handler) { "control event handler is not installed" }.invoke(event)
    }
}

internal class LifecycleAssetTransport : SessionAssetTransport {
    var configuredAuthentication: com.aessam.comeoverhere.core.SessionGuideAuthentication? = null
    override fun configureGuideAuthentication(authentication: com.aessam.comeoverhere.core.SessionGuideAuthentication) { configuredAuthentication = authentication }
    var configureCalls = 0
    data class Sent(val kind: SessionMessageKind, val payload: ByteArray, val to: UUID?)

    override var isActive = false
    override var hostIP: String? = null
    var startGuideCalls = 0
    var startGuestCalls = 0
    var stopCalls = 0
    var clearSessionCalls = 0
    val sent = CopyOnWriteArrayList<Sent>()
    var startGuideError: Exception? = null
    private var handler: ((SessionAssetEvent) -> Unit)? = null

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) { configureCalls += 1 }

    override fun setEventHandler(handler: ((SessionAssetEvent) -> Unit)?) {
        this.handler = handler
    }

    override fun startGuide() {
        startGuideCalls += 1
        startGuideError?.let { throw it }
        isActive = true
    }

    override fun startGuest() {
        startGuestCalls += 1
        isActive = true
    }

    override fun send(kind: SessionMessageKind, payload: ByteArray, participantID: UUID?) {
        sent += Sent(kind, payload, participantID)
    }

    override fun stop() {
        stopCalls += 1
        isActive = false
    }

    override fun clearSession() {
        clearSessionCalls += 1
        isActive = false
    }

    fun emit(event: SessionAssetEvent) {
        checkNotNull(handler) { "asset event handler is not installed" }.invoke(event)
    }
}

internal class FakeAudioEngine : AudioEngineInterface {
    override var isCapturing = false
    override var isPlaying = false
    override var playbackFailureHandler: ((Int) -> Unit)? = null
    override var onPlaybackBufferAccepted: (() -> Unit)? = null
    override var onOutputForcedPrivate: (() -> Unit)? = null
    override var onAudioFocusLost: (() -> Unit)? = null
    var startCaptureCalls = 0
    var startCaptureError: Exception? = null
    var startPlaybackError: Exception? = null
    var startPlaybackCalls = 0
    var acceptPlayback = true
    /** Returned by [startCapture]; defaults to an open stream that never completes on its own. */
    var captureFlow: Flow<ByteArray> = flow { awaitCancellation() }
    var onStartCapture: (() -> Unit)? = null
    var appliedListenerOutput = ListenerOutput.PRIVATE_AUDIO
    val played = CopyOnWriteArrayList<ByteArray>()

    override fun startCapture(): Flow<ByteArray> {
        startCaptureCalls += 1
        onStartCapture?.invoke()
        startCaptureError?.let { throw it }
        isCapturing = true
        return captureFlow
    }

    override fun stopCapture() { isCapturing = false }
    override fun startPlayback() {
        startPlaybackCalls++
        startPlaybackError?.let { throw it }
        isPlaying = true
    }
    override fun enqueuePlayback(data: ByteArray) {
        if (!isPlaying || !acceptPlayback) return
        played += data
        onPlaybackBufferAccepted?.invoke()
    }
    override fun stopPlayback() { isPlaying = false }
    override fun setListenerOutput(output: ListenerOutput) { appliedListenerOutput = output }
}

internal class FakeLocalGuidance : LocalGuidanceInterface {
    override val status = MutableStateFlow(LocalGuidanceStatus.IDLE)
    override val position = MutableStateFlow<LocalDevicePosition?>(null)
    override val headingDegrees = MutableStateFlow<Double?>(null)
    override val magneticHeadingDegrees = MutableStateFlow<Double?>(null)
    override val headingAccuracy = MutableStateFlow<Int?>(null)
    var stopCalls = 0

    override fun start() = Unit
    override fun startHeadingOnly() = Unit
    override fun stop() { stopCalls += 1 }
}
