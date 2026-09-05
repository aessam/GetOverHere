package com.aessam.comeoverhere.service

import android.util.Log
import com.aessam.comeoverhere.core.*
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantRegistry
import com.aessam.toursession.PresentationSnapshotPayload
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TargetSnapshotPayload
import com.aessam.toursession.BearingSnapshotPayload
import com.aessam.toursession.TourVisualMode
import com.aessam.toursession.VisualFocusSnapshotPayload
import com.aessam.toursession.SessionRouteLease
import com.aessam.toursession.SessionTransportRoute
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Coordinates audio, presentation state, and tour assets for one local session.
 * - Creator of a channel is the ONLY speaker
 * - Everyone else listens
 * - Android NSD handles discovery on the shared local network
 * - Independent authenticated TCP lanes carry audio, control, and assets
 */

enum class ListenState { IDLE, LISTENING, BROADCASTING }
enum class SessionConnectionState { IDLE, CONNECTING, CONNECTED, RECONNECTING, FAILED }
sealed interface OfflineMapStatus {
    data object Unavailable : OfflineMapStatus
    data object Transferring : OfflineMapStatus
    data object Ready : OfflineMapStatus
    data class Failed(val message: String) : OfflineMapStatus
}

interface ChannelServiceProtocol {
    val channels: StateFlow<List<Channel>>
    val activeChannelID: StateFlow<String?>
    val listenState: StateFlow<ListenState>
    /** Guests admitted on the audio lane. */
    val listenerCount: StateFlow<Int>
    /** Guests admitted on the control lane; independent of audio readiness (FND-13). */
    val connectedGuestCount: StateFlow<Int>
    /** Non-null only while listening on the loudspeaker in a non-failed session (FND-13). */
    val speakerFeedbackWarning: StateFlow<String?>
    val readyParticipantCount: StateFlow<Int>
    val connectedPeers: StateFlow<List<PeerInfo>>
    val listenerOutput: StateFlow<ListenerOutput>
    val presentationSnapshot: StateFlow<PresentationSnapshotPayload?>
    val slides: StateFlow<List<TourAssetDescriptor>>
    val readySlideFiles: StateFlow<Map<String, File>>
    val isImportingSlides: StateFlow<Boolean>
    val isImportingMap: StateFlow<Boolean>
    val offlineMapConfiguration: StateFlow<OfflineMapConfiguration?>
    val offlineMapStatus: StateFlow<OfflineMapStatus>
    val tourFeatureError: StateFlow<String?>
    val tourCode: StateFlow<String?>
    val isRoomLocked: StateFlow<Boolean>
    val isUpdatingRoomAccess: StateFlow<Boolean>
    val roomAccessError: StateFlow<String?>
    fun updateRoomAccess(locked: Boolean, code: String)
    val connectionState: StateFlow<SessionConnectionState>
    val reconnectAttempt: StateFlow<Int>
    val targetSnapshot: StateFlow<TargetSnapshotPayload?>
    val bearingSnapshot: StateFlow<BearingSnapshotPayload?>
    val visualFocusSnapshot: StateFlow<VisualFocusSnapshotPayload?>
    val localGuidanceService: LocalGuidanceInterface
    val localPeerID: String
    val audioQuality: AudioQuality

    fun start()
    fun stop()
    fun createChannel(name: String, quality: AudioQuality = AudioQuality.STANDARD)
    fun joinChannel(channel: Channel, tourCode: String)
    fun setListenerOutput(output: ListenerOutput)
    fun leaveChannel()
    fun importSlides(imports: List<SlideImport>)
    fun moveSlide(assetID: String, destinationIndex: Int)
    fun removeSlide(assetID: String)
    fun importOfflineMap(import: OfflineMapImport)
    fun showSlide(assetID: String? = null)
    fun hideSlides()
    fun previousSlide()
    fun nextSlide()
    fun setVisualFocus(mode: TourVisualMode)
    fun setTarget(latitude: Double, longitude: Double, label: String = "")
    fun clearTarget()
    fun shareCurrentBearing()
    fun clearBearing()
}

data class SlideImport(val bytes: ByteArray, val mimeType: String)
data class OfflineMapImport(val styleBytes: ByteArray, val temporaryArchive: File)

class ChannelService(
    private val coordinator: NetworkCoordinator,
    private val audioEngine: AudioEngineInterface,
    private val scope: CoroutineScope,
    private val tourControlService: TourControlService,
    private val assetTransferService: TourAssetTransferService,
    private val contentStore: TourContentStore,
    override val localGuidanceService: LocalGuidanceInterface,
    /** Base of the ADR-034 exponential reconnect backoff; tests shorten it (DSCN-23). */
    private val reconnectBaseDelayMillis: Long = 1_000L,
    private val roomAdmission: RoomAdmissionInterface = RoomAdmissionTransport(),
) : ChannelServiceProtocol {

    private val _channels = MutableStateFlow<List<Channel>>(emptyList())
    override val channels: StateFlow<List<Channel>> = _channels.asStateFlow()

    private val _activeChannelID = MutableStateFlow<String?>(null)
    override val activeChannelID: StateFlow<String?> = _activeChannelID.asStateFlow()

    private val _listenState = MutableStateFlow(ListenState.IDLE)
    override val listenState: StateFlow<ListenState> = _listenState.asStateFlow()

    private val _listenerCount = MutableStateFlow(0)
    override val listenerCount: StateFlow<Int> = _listenerCount.asStateFlow()

    private val _readyParticipantCount = MutableStateFlow(0)
    override val readyParticipantCount: StateFlow<Int> = _readyParticipantCount.asStateFlow()

    private val _listenerOutput = MutableStateFlow(ListenerOutput.PRIVATE_AUDIO)
    override val listenerOutput: StateFlow<ListenerOutput> = _listenerOutput.asStateFlow()

    override val presentationSnapshot = tourControlService.snapshot
    override val slides = tourControlService.slides
    override val targetSnapshot = tourControlService.targetSnapshot
    override val bearingSnapshot = tourControlService.bearingSnapshot
    override val visualFocusSnapshot = tourControlService.visualFocusSnapshot

    private val _readySlideFiles = MutableStateFlow<Map<String, File>>(emptyMap())
    override val readySlideFiles: StateFlow<Map<String, File>> = _readySlideFiles.asStateFlow()

    private val _isImportingSlides = MutableStateFlow(false)
    override val isImportingSlides: StateFlow<Boolean> = _isImportingSlides.asStateFlow()

    private val _isImportingMap = MutableStateFlow(false)
    override val isImportingMap: StateFlow<Boolean> = _isImportingMap.asStateFlow()

    private val _offlineMapConfiguration = MutableStateFlow<OfflineMapConfiguration?>(null)
    override val offlineMapConfiguration: StateFlow<OfflineMapConfiguration?> =
        _offlineMapConfiguration.asStateFlow()

    private val _offlineMapStatus = MutableStateFlow<OfflineMapStatus>(OfflineMapStatus.Unavailable)
    override val offlineMapStatus: StateFlow<OfflineMapStatus> = _offlineMapStatus.asStateFlow()

    private val _tourFeatureError = MutableStateFlow<String?>(null)
    override val tourFeatureError: StateFlow<String?> = _tourFeatureError.asStateFlow()

    private val _tourCode = MutableStateFlow<String?>(null)
    override val tourCode: StateFlow<String?> = _tourCode.asStateFlow()
    private val _isRoomLocked = MutableStateFlow(false)
    override val isRoomLocked = _isRoomLocked.asStateFlow()
    private val _isUpdatingRoomAccess = MutableStateFlow(false)
    override val isUpdatingRoomAccess = _isUpdatingRoomAccess.asStateFlow()
    private val _roomAccessError = MutableStateFlow<String?>(null)
    override val roomAccessError = _roomAccessError.asStateFlow()
    private var roomAccessAttempt = 0L

    private val _connectionState = MutableStateFlow(SessionConnectionState.IDLE)
    override val connectionState: StateFlow<SessionConnectionState> = _connectionState.asStateFlow()

    private val _reconnectAttempt = MutableStateFlow(0)
    override val reconnectAttempt: StateFlow<Int> = _reconnectAttempt.asStateFlow()

    override val connectedGuestCount: StateFlow<Int> = tourControlService.connectedGuestCount

    override val speakerFeedbackWarning: StateFlow<String?> =
        combine(_listenState, _listenerOutput, _connectionState) { state, output, connection ->
            if (
                state == ListenState.LISTENING &&
                output == ListenerOutput.SPEAKER &&
                connection != SessionConnectionState.FAILED
            ) {
                SPEAKER_FEEDBACK_WARNING
            } else {
                null
            }
        }.stateIn(scope, SharingStarted.Eagerly, null)

    override val connectedPeers: StateFlow<List<PeerInfo>> = coordinator.controlPlane.connectedPeers
    override val localPeerID: String get() = coordinator.controlPlane.localPeer.id
    override var audioQuality: AudioQuality = AudioQuality.STANDARD

    private var captureJob: Job? = null
    private var reconnectJob: Job? = null
    private var guestCredential: SessionCredential? = null
    /** Monotonic guard for continuations that resume after the off-main credential stretch (DSCN-20). */
    private var sessionAttempt = 0L
    /**
     * Lane-ownership generation: bumped only where the lanes change hands (a session start,
     * [stopCurrentActivity], or an End Tour). The deferred End Tour teardown compares it, never
     * [sessionAttempt], so a no-op leave or an invalid join cannot skip it (ADR-048).
     */
    private var sessionGeneration = 0L
    /** Audio-lane losses since the last delivered PCM buffer; terminal at 5 (DSCN-19). */
    private val consecutiveAudioLaneFailures = AtomicInteger(0)
    private var participantRegistry = ParticipantRegistry()
    private var activeGuestRoute: SessionTransportRoute? = null
    private var attemptedGuestRoutes = mutableSetOf<SessionTransportRoute>()
    private var routeLease = SessionRouteLease()

    val activeChannel: Channel?
        get() = _channels.value.find { it.id == _activeChannelID.value }

    val isCreator: Boolean
        get() = activeChannel?.createdBy == coordinator.controlPlane.localPeer.id

    companion object {
        private const val TAG = "ChannelService"
        const val SPEAKER_FEEDBACK_WARNING =
            "Speaker output can feed back into the guide's microphone. Use the earpiece or headphones near the guide."

        /** Single source of the user-facing version-mismatch text for every guest and guide path. */
        fun versionMismatchMessage(remoteMajor: Int, localMajor: Int): String =
            "Tour protocol version mismatch (remote $remoteMajor, local $localMajor). Update the older app."
    }

    init {
        audioEngine.playbackFailureHandler = { code ->
            _tourFeatureError.value = "Tour audio playback failed ($code)"
        }
        audioEngine.onOutputForcedPrivate = { _listenerOutput.value = ListenerOutput.PRIVATE_AUDIO }
        audioEngine.onAudioFocusLost = { _tourFeatureError.value = "Another app took over audio" }
        assetTransferService.setEventHandler { event ->
            when (event) {
                is TourAssetTransferEvent.ManifestReceived -> {
                    tourControlService.acceptTourPack(event.manifest)
                    refreshOfflineMap()
                }
                is TourAssetTransferEvent.AssetReady -> {
                    _readySlideFiles.value = _readySlideFiles.value + (event.assetID to event.file)
                    refreshOfflineMap()
                }
                is TourAssetTransferEvent.ParticipantReady -> Unit
                is TourAssetTransferEvent.ParticipantReadinessChanged -> {
                    _readyParticipantCount.value = event.readyCount
                }
                is TourAssetTransferEvent.Failed -> {
                    _tourFeatureError.value = event.message
                    Log.e(TAG, "Tour asset transfer failed")
                }
            }
        }
        tourControlService.setConnectionEventHandler { event ->
            scope.launch { handleControlConnectionEvent(event) }
        }
    }

    // MARK: - Lifecycle

    override fun start() {
        listenForChannelCommands()
        listenForPeerEvents()
        startPeriodicBroadcast()
        Log.i(TAG, "ChannelService started")
    }

    override fun stop() {
        stopCurrentActivity()
    }

    // MARK: - Channel Management

    override fun createChannel(name: String, quality: AudioQuality) {
        sessionAttempt += 1
        audioQuality = quality
        val channel = Channel(
            id = UUID.randomUUID().toString(),
            name = name,
            createdAt = nowAsSwiftRef(),
            createdBy = coordinator.controlPlane.localPeer.id,
            roomAdmissionVersion = 1,
            isRoomLocked = false,
        )
        val sessionID = UUID.fromString(channel.id)
        val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }
            .getOrElse {
                Log.e(TAG, "Cannot create session with non-UUID participant identity", it)
                return
            }
        val code = SessionCredential.generateShortCode()
        val attempt = sessionAttempt
        scope.launch {
            val credential = withContext(Dispatchers.Default) { SessionCredential.derive(code, sessionID) }
            if (attempt != sessionAttempt) {
                Log.i(TAG, "Discarding a stale guide credential; the session was replaced during the stretch")
                return@launch
            }
            startGuideSession(channel, sessionID, participantID, code, credential)
        }
    }

    private fun startGuideSession(
        channel: Channel,
        sessionID: UUID,
        participantID: UUID,
        code: String,
        credential: SessionCredential,
    ) {
        try {
            contentStore.beginPack(sessionID, channel.name)
            val emptyManifest = contentStore.manifestPayload()
            sessionGeneration += 1
            tourControlService.configureSession(
                sessionID,
                participantID,
                coordinator.controlPlane.localPeer.displayName,
                ParticipantPlatform.ANDROID,
                credential,
            )
            assetTransferService.configureSession(
                sessionID,
                participantID,
                coordinator.controlPlane.localPeer.displayName,
                ParticipantPlatform.ANDROID,
                credential,
            )
            // Every lane start is synchronous and throwing (ADR-046); nothing is committed or
            // published until control, asset, audio, and microphone capture are all running.
            tourControlService.startGuide(sessionID)
            assetTransferService.startGuideWithEmptyTourPack(emptyManifest)

            val plane = coordinator.selectAudioPlane()
            participantRegistry = ParticipantRegistry()
            _listenerCount.value = 0
            _readyParticipantCount.value = 0
            plane.configureSession(
                sessionID = sessionID,
                participantID = participantID,
                displayName = coordinator.controlPlane.localPeer.displayName,
                platform = ParticipantPlatform.ANDROID,
                credential = credential,
            )
            plane.setSessionEventHandler { event ->
                scope.launch { handleAudioSessionEvent(event) }
            }
            plane.startBroadcasting(channelID = channel.id, quality = audioQuality)
            startCapturing(plane, channel.id)
            roomAdmission.start(sessionID, code)

            _readySlideFiles.value = emptyMap()
            _offlineMapConfiguration.value = null
            _offlineMapStatus.value = OfflineMapStatus.Unavailable
            _tourFeatureError.value = null
            _tourCode.value = ""
            _isRoomLocked.value = false
            _roomAccessError.value = null

            _channels.value = _channels.value + channel
            _activeChannelID.value = channel.id
            _listenState.value = ListenState.BROADCASTING
            _connectionState.value = SessionConnectionState.CONNECTED
            guestCredential = null

            broadcastChannelAnnounce(channel)
        } catch (error: Exception) {
            rollbackFailedGuideSession(channel.id)
            _tourCode.value = null
            _tourFeatureError.value = error.message ?: error.javaClass.simpleName
            Log.e(TAG, "Cannot start tour features (${error.javaClass.simpleName})")
            return
        }
        Log.i(TAG, "Created megaphone (quality: ${audioQuality.label})")
    }

    /** Mirrors the iOS rollback: every lane is cleared and the NSD record is withdrawn (FND-2). */
    private fun rollbackFailedGuideSession(channelID: String) {
        roomAdmission.stop()
        audioEngine.stopCapture()
        captureJob?.cancel()
        captureJob = null
        coordinator.activeAudioPlane?.setSessionEventHandler(null)
        coordinator.activeAudioPlane?.clearSession()
        tourControlService.clearSession()
        assetTransferService.clearSession()
        localGuidanceService.stop()
        _channels.value = _channels.value.filter { it.id != channelID }
        _activeChannelID.value = null
        _listenState.value = ListenState.IDLE
        _connectionState.value = SessionConnectionState.FAILED
        guestCredential = null
        participantRegistry = ParticipantRegistry()
        _listenerCount.value = 0
        _readyParticipantCount.value = 0
        coordinator.controlPlane.broadcast(BLECommand.ChannelEnded(channelID = channelID))
    }

    override fun joinChannel(channel: Channel, tourCode: String) {
        if (_activeChannelID.value == null && _connectionState.value == SessionConnectionState.CONNECTING) return
        sessionAttempt += 1
        val sessionID = runCatching { UUID.fromString(channel.id) }
            .getOrElse {
                Log.e(TAG, "Cannot join session with non-UUID channel identity", it)
                return
            }
        val normalizedCode = SessionCredential.normalize(tourCode)
        val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }
            .getOrElse {
                Log.e(TAG, "Cannot join session with non-UUID participant identity", it)
                return
            }
        val attempt = sessionAttempt
        scope.launch {
            val credential = try {
                if (_activeChannelID.value == null && channel.roomAdmissionVersion == 1) {
                    _connectionState.value = SessionConnectionState.CONNECTING
                }
                withContext(Dispatchers.IO) {
                    if (channel.roomAdmissionVersion != null && channel.roomAdmissionVersion != 0) {
                        require(channel.roomAdmissionVersion == 1) { "Unsupported room admission version." }
                        val host = requireNotNull(channel.audioHostIP) { "Guide network address is unavailable." }
                        val secret = roomAdmission.join(host, sessionID, tourCode.ifEmpty { null })
                        SessionCredential.derive(secret, sessionID)
                    } else SessionCredential.derive(normalizedCode, sessionID)
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (attempt == sessionAttempt) {
                    _tourFeatureError.value = error.message ?: error.javaClass.simpleName
                    if (_activeChannelID.value == null) _connectionState.value = SessionConnectionState.FAILED
                } else {
                    Log.i(TAG, "Discarding a stale guest credential failure; the session was replaced during the stretch")
                }
                return@launch
            }
            if (attempt != sessionAttempt) {
                Log.i(TAG, "Discarding a stale guest credential; the session was replaced during the stretch")
                return@launch
            }
            startGuestSession(channel, sessionID, participantID, normalizedCode, credential)
        }
    }

    private fun startGuestSession(
        channel: Channel,
        sessionID: UUID,
        participantID: UUID,
        normalizedCode: String,
        credential: SessionCredential,
    ) {
        stopCurrentActivity()
        _readySlideFiles.value = emptyMap()
        _readyParticipantCount.value = 0
        _offlineMapConfiguration.value = null
        _offlineMapStatus.value = OfflineMapStatus.Transferring
        _tourFeatureError.value = null
        _tourCode.value = normalizedCode
        guestCredential = credential
        _reconnectAttempt.value = 0
        _activeChannelID.value = channel.id
        _listenState.value = ListenState.LISTENING
        _connectionState.value = SessionConnectionState.CONNECTING
        setListenerOutput(ListenerOutput.PRIVATE_AUDIO)
        attemptedGuestRoutes.clear()
        routeLease.reset()
        activeGuestRoute = null
        sessionGeneration += 1
        tryNextGuestRoute(channel, sessionID, participantID, credential)
        Log.i(TAG, "Joined megaphone")
    }

    override fun importSlides(imports: List<SlideImport>) {
        if (_listenState.value != ListenState.BROADCASTING || imports.isEmpty()) return
        scope.launch(Dispatchers.IO) {
            _isImportingSlides.value = true
            try {
                imports.forEach { contentStore.importSlide(it.bytes, it.mimeType) }
                val manifest = contentStore.manifestPayload()
                assetTransferService.hostTourPack(manifest, contentStore.sourcesByAssetID)
                tourControlService.updateDeck(manifest.packID, manifest.assets)
                _readySlideFiles.value = contentStore.sourcesByAssetID
                _tourFeatureError.value = null
            } catch (error: Exception) {
                _tourFeatureError.value = error.message ?: error.javaClass.simpleName
                Log.e(TAG, "Slide import failed (${error.javaClass.simpleName})")
            } finally {
                _isImportingSlides.value = false
            }
        }
    }

    override fun moveSlide(assetID: String, destinationIndex: Int) {
        if (_listenState.value != ListenState.BROADCASTING) return
        scope.launch(Dispatchers.IO) {
            try {
                contentStore.moveSlide(assetID, destinationIndex)
                publishCurrentTourPack()
                _tourFeatureError.value = null
            } catch (error: Exception) {
                _tourFeatureError.value = error.message ?: error.javaClass.simpleName
                Log.e(TAG, "Slide reorder failed (${error.javaClass.simpleName})")
            }
        }
    }

    override fun removeSlide(assetID: String) {
        if (_listenState.value != ListenState.BROADCASTING) return
        scope.launch(Dispatchers.IO) {
            try {
                contentStore.removeSlide(assetID)
                publishCurrentTourPack()
                _tourFeatureError.value = null
            } catch (error: Exception) {
                _tourFeatureError.value = error.message ?: error.javaClass.simpleName
                Log.e(TAG, "Slide removal failed (${error.javaClass.simpleName})")
            }
        }
    }

    override fun importOfflineMap(import: OfflineMapImport) {
        if (_listenState.value != ListenState.BROADCASTING) return
        scope.launch(Dispatchers.IO) {
            _isImportingMap.value = true
            _offlineMapStatus.value = OfflineMapStatus.Transferring
            try {
                contentStore.importOfflineMap(import.styleBytes, import.temporaryArchive)
                val manifest = contentStore.manifestPayload()
                assetTransferService.hostTourPack(manifest, contentStore.sourcesByAssetID)
                tourControlService.updateDeck(manifest.packID, manifest.assets)
                _readySlideFiles.value = contentStore.sourcesByAssetID
                refreshOfflineMap()
                _tourFeatureError.value = null
            } catch (error: Exception) {
                _offlineMapStatus.value = OfflineMapStatus.Failed(
                    error.message ?: error.javaClass.simpleName,
                )
                _tourFeatureError.value = error.message ?: error.javaClass.simpleName
                Log.e(TAG, "Offline map import failed (${error.javaClass.simpleName})")
            } finally {
                if (!import.temporaryArchive.delete() && import.temporaryArchive.exists()) {
                    Log.e(TAG, "Could not remove temporary map import")
                }
                _isImportingMap.value = false
            }
        }
    }

    override fun showSlide(assetID: String?) = runPresentationAction {
        tourControlService.showSlide(assetID)
    }

    override fun hideSlides() = runPresentationAction(tourControlService::hide)

    override fun previousSlide() = runPresentationAction(tourControlService::goPrevious)

    override fun nextSlide() = runPresentationAction(tourControlService::goNext)

    override fun setVisualFocus(mode: TourVisualMode) = runPresentationAction {
        tourControlService.setVisualFocus(mode)
    }

    override fun setTarget(latitude: Double, longitude: Double, label: String) =
        runPresentationAction { tourControlService.setTarget(latitude, longitude, label) }

    override fun clearTarget() = runPresentationAction(tourControlService::clearTarget)

    override fun shareCurrentBearing() = runPresentationAction {
        val heading = localGuidanceService.magneticHeadingDegrees.value
            ?: throw PresentationServiceException("A valid compass heading is required")
        tourControlService.shareBearing(heading)
    }

    override fun clearBearing() = runPresentationAction(tourControlService::clearBearing)

    override fun setListenerOutput(output: ListenerOutput) {
        _listenerOutput.value = output
        audioEngine.setListenerOutput(output)
    }

    override fun leaveChannel() {
        roomAdmission.stop()
        roomAccessAttempt++
        _isUpdatingRoomAccess.value = false
        sessionAttempt += 1
        val ch = activeChannel ?: return
        val isGuide = ch.createdBy == coordinator.controlPlane.localPeer.id
        sessionGeneration += 1
        val generation = sessionGeneration
        if (isGuide) {
            // UI state ends now; the authenticated leave is flushed off the main thread and the
            // lanes are cleared after delivery unless a newer session replaced them (ADR-048, DSCN-27).
            audioEngine.stopCapture()
            captureJob?.cancel()
            captureJob = null
            _channels.value = _channels.value.filter { it.id != ch.id }
            _activeChannelID.value = null
            _listenState.value = ListenState.IDLE
            _tourCode.value = null
            _connectionState.value = SessionConnectionState.IDLE
            participantRegistry = ParticipantRegistry()
            _listenerCount.value = 0
            _readyParticipantCount.value = 0
            coordinator.controlPlane.broadcast(BLECommand.ChannelEnded(channelID = ch.id))
            scope.launch {
                try {
                    tourControlService.endGuideSession()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    Log.e(TAG, "Failed to send authenticated session end (${error.javaClass.simpleName})")
                }
                if (sessionGeneration == generation) {
                    // This leave already invalidated older stretches; a create/join started inside
                    // the flush window is the user's newest action and must survive the teardown.
                    stopCurrentActivity(discardingPendingStretch = false)
                } else {
                    Log.i(TAG, "Skipping the deferred lane teardown; a newer session owns the lanes")
                }
            }
        } else {
            stopCurrentActivity()
            _activeChannelID.value = null
            _listenState.value = ListenState.IDLE
            _tourCode.value = null
            _connectionState.value = SessionConnectionState.IDLE
            guestCredential = null
        }
        Log.i(TAG, "Left channel")
    }

    // MARK: - Private

    private fun startCapturing(plane: AudioPlane, channelID: String) {
        // The microphone preflight throws synchronously here, into startGuideSession's catch (FND-2).
        val pcm = audioEngine.startCapture()
        captureJob = scope.launch {
            try {
                pcm.collect { pcmData ->
                    if (!isActive) return@collect
                    plane.sendAudio(pcmData)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.e(TAG, "Capture stream failed (${error.javaClass.simpleName})")
                if (_listenState.value == ListenState.BROADCASTING) {
                    // DSCN-12: control and asset lanes stay up; the guide decides whether to end the tour.
                    _tourFeatureError.value = "Microphone capture stopped"
                }
            }
        }
    }

    /**
     * [discardingPendingStretch] is false only from the deferred End Tour teardown: that leave
     * already bumped [sessionAttempt], and a create/join started inside the flush window must
     * survive it (ADR-048).
     */
    override fun updateRoomAccess(locked: Boolean, code: String) {
        val channel = activeChannel ?: return
        if (!isCreator) return
        roomAccessAttempt++
        val attempt = roomAccessAttempt
        val generation = sessionGeneration
        _isUpdatingRoomAccess.value = true
        _roomAccessError.value = null
        scope.launch {
            try {
                val policy = withContext(Dispatchers.Default) {
                    RoomAccessPolicy(UUID.fromString(channel.id), if (locked) code else null)
                }
                if (attempt != roomAccessAttempt || generation != sessionGeneration || !isCreator) return@launch
                roomAdmission.update(policy)
                _isRoomLocked.value = locked
                _tourCode.value = code
                val updated = channel.copy(isRoomLocked = locked)
                _channels.value = _channels.value.map { if (it.id == channel.id) updated else it }
                broadcastChannelAnnounce(updated)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (attempt != roomAccessAttempt || generation != sessionGeneration) return@launch
                _roomAccessError.value = error.message ?: error.javaClass.simpleName
                Log.e(TAG, "Room access update failed (${error.javaClass.simpleName})")
            }
            _isUpdatingRoomAccess.value = false
        }
    }

    private fun stopCurrentActivity(discardingPendingStretch: Boolean = true) {
        roomAdmission.stop()
        roomAccessAttempt++
        _isUpdatingRoomAccess.value = false
        if (discardingPendingStretch) sessionAttempt += 1
        sessionGeneration += 1
        reconnectJob?.cancel()
        reconnectJob = null
        _reconnectAttempt.value = 0
        consecutiveAudioLaneFailures.set(0)
        guestCredential = null
        if (_listenState.value == ListenState.BROADCASTING) {
            audioEngine.stopCapture()
            captureJob?.cancel()
            captureJob = null
        } else if (_listenState.value == ListenState.LISTENING) {
            audioEngine.stopPlayback()
        }
        coordinator.activeAudioPlane?.setSessionEventHandler(null)
        coordinator.activeAudioPlane?.clearSession()
        tourControlService.clearSession()
        assetTransferService.clearSession()
        localGuidanceService.stop()
        _offlineMapConfiguration.value = null
        _offlineMapStatus.value = OfflineMapStatus.Unavailable
        participantRegistry = ParticipantRegistry()
        _listenerCount.value = 0
        _readyParticipantCount.value = 0
        _connectionState.value = SessionConnectionState.IDLE
        activeGuestRoute = null
        attemptedGuestRoutes.clear()
        routeLease.reset()
    }

    private fun refreshOfflineMap() {
        val manifest = if (isCreator) {
            runCatching(contentStore::manifestPayload).getOrNull()
        } else {
            assetTransferService.manifest
        }
        if (manifest == null) {
            _offlineMapConfiguration.value = null
            _offlineMapStatus.value = if (_listenState.value == ListenState.LISTENING) {
                OfflineMapStatus.Transferring
            } else {
                OfflineMapStatus.Unavailable
            }
            return
        }
        val hasStyle = manifest.assets.any { it.kind == com.aessam.toursession.TourAssetKind.MAP_STYLE }
        val hasArchive = manifest.assets.any { it.kind == com.aessam.toursession.TourAssetKind.MAP_ARCHIVE }
        if (!hasStyle && !hasArchive) {
            _offlineMapConfiguration.value = null
            _offlineMapStatus.value = OfflineMapStatus.Unavailable
            return
        }
        if (!hasStyle || !hasArchive) {
            val message = "The tour pack contains an incomplete offline map"
            _offlineMapConfiguration.value = null
            _offlineMapStatus.value = OfflineMapStatus.Failed(message)
            _tourFeatureError.value = message
            return
        }
        val files = if (isCreator) contentStore.sourcesByAssetID else assetTransferService.readyFilesByAssetID
        try {
            _offlineMapConfiguration.value = OfflineMapPack.resolve(manifest, files)
            _offlineMapStatus.value = OfflineMapStatus.Ready
        } catch (error: OfflineMapPackException) {
            if (error.message?.endsWith("is not ready") == true) {
                _offlineMapConfiguration.value = null
                _offlineMapStatus.value = OfflineMapStatus.Transferring
            } else {
                _offlineMapConfiguration.value = null
                _offlineMapStatus.value = OfflineMapStatus.Failed(
                    error.message ?: error.javaClass.simpleName,
                )
                _tourFeatureError.value = error.message
            }
        }
    }

    private fun publishCurrentTourPack() {
        val manifest = contentStore.manifestPayload()
        assetTransferService.hostTourPack(manifest, contentStore.sourcesByAssetID)
        tourControlService.updateDeck(manifest.packID, manifest.assets)
        _readySlideFiles.value = contentStore.sourcesByAssetID
    }

    private fun broadcastChannelAnnounce(channel: Channel) {
        if (channel.createdBy != coordinator.controlPlane.localPeer.id) return
        val announce = BLECommand.ChannelAnnounce(
            channelID = channel.id,
            channelName = channel.name,
            createdBy = channel.createdBy,
            audioQuality = audioQuality,
            wifiSSID = null,
            audioHostIP = channel.audioHostIP,
            roomAdmissionVersion = channel.roomAdmissionVersion,
            isRoomLocked = channel.isRoomLocked,
        )
        coordinator.controlPlane.broadcast(announce)
    }

    private fun broadcastAllChannels() {
        _channels.value.forEach { broadcastChannelAnnounce(it) }
    }

    // MARK: - Periodic Broadcast

    private fun startPeriodicBroadcast() {
        scope.launch {
            while (isActive) {
                delay(5000)
                if (_channels.value.isNotEmpty()) {
                    broadcastAllChannels()
                }
            }
        }
    }

    // MARK: - Command Listeners

    private fun listenForChannelCommands() {
        scope.launch {
            coordinator.controlPlane.commands.collect { (command, _) ->
                when (command) {
                    is BLECommand.ChannelAnnounce -> {
                        val existing = _channels.value.find { it.id == command.channelID }
                        if (existing != null) {
                            val updated = existing.copy(
                                name = command.channelName,
                                audioHostIP = command.audioHostIP,
                                hasWiFiAware = false,
                                roomAdmissionVersion = command.roomAdmissionVersion,
                                isRoomLocked = command.isRoomLocked ?: true,
                            )
                            _channels.value = _channels.value.map {
                                if (it.id == command.channelID) updated else it
                            }
                            Log.i(TAG, "Updated discovered megaphone")

                            if (_activeChannelID.value == updated.id &&
                                _listenState.value == ListenState.LISTENING &&
                                existing.audioHostIP != updated.audioHostIP) {
                                // Discovery may only reconfigure the existing credential (FND-6, ADR-036).
                                restartGuestTransports(updated)
                            }
                        } else {
                            val channel = Channel(
                                id = command.channelID,
                                name = command.channelName,
                                createdAt = nowAsSwiftRef(),
                                createdBy = command.createdBy,
                                audioHostIP = command.audioHostIP,
                                roomAdmissionVersion = command.roomAdmissionVersion,
                                isRoomLocked = command.isRoomLocked ?: true,
                            )
                            _channels.value = _channels.value + channel
                            Log.i(TAG, "Discovered megaphone")
                        }
                    }
                    is BLECommand.ChannelUnavailable -> handleDiscoveryUnavailable(command.channelID)
                    is BLECommand.ChannelEnded -> handleDiscoveryUnavailable(command.channelID)
                    else -> { /* heartbeat, vote, wifi handled by coordinator */ }
                }
            }
        }
    }

    private fun listenForPeerEvents() {
        scope.launch {
            coordinator.controlPlane.peerEvents.collect { event ->
                when (event) {
                    is PeerEvent.Connected -> {
                        broadcastAllChannels()
                    }
                    else -> {}
                }
            }
        }
    }

    private fun handleAudioSessionEvent(event: AudioSessionEvent) {
        when (event) {
            is AudioSessionEvent.Joined -> participantRegistry.register(event.participant)
            is AudioSessionEvent.Disconnected -> participantRegistry.disconnect(event.connectionID)
            is AudioSessionEvent.VersionMismatch -> {
                // DSCN-13: one legacy guest must not end the guide's tour. The transport already
                // closed that connection; the guide only sees the reason.
                _tourFeatureError.value = versionMismatchMessage(event.remoteMajor, event.localMajor)
                Log.e(TAG, "Rejected a legacy guest on the audio lane")
            }
            is AudioSessionEvent.Failed -> {
                _connectionState.value = SessionConnectionState.FAILED
                _tourFeatureError.value = event.message
            }
        }
        _listenerCount.value = participantRegistry.listenerCount
        Log.i(TAG, "Session membership changed: listeners=${_listenerCount.value}")
    }

    private fun tryNextGuestRoute(
        channel: Channel,
        sessionID: UUID,
        participantID: UUID,
        credential: SessionCredential,
    ) {
        val hostIP = channel.audioHostIP
        if (hostIP == null) {
            _connectionState.value = SessionConnectionState.FAILED
            _tourFeatureError.value = "No local LAN route is available"
            return
        }
        val route = SessionTransportRoute.LOCAL_LAN
        if (route in attemptedGuestRoutes) {
            activeGuestRoute = null
            scheduleReconnect("Could not authenticate the local LAN route to the guide")
            return
        }
        attemptedGuestRoutes += SessionTransportRoute.LOCAL_LAN
        activeGuestRoute = SessionTransportRoute.LOCAL_LAN
        _connectionState.value = SessionConnectionState.CONNECTING
        startGuestTransports(channel, hostIP, sessionID, participantID, credential)
    }

    private fun startGuestTransports(
        channel: Channel,
        hostIP: String,
        sessionID: UUID,
        participantID: UUID,
        credential: SessionCredential,
    ) {
        tourControlService.configureSession(
            sessionID,
            participantID,
            coordinator.controlPlane.localPeer.displayName,
            ParticipantPlatform.ANDROID,
            credential,
        )
        assetTransferService.configureSession(
            sessionID,
            participantID,
            coordinator.controlPlane.localPeer.displayName,
            ParticipantPlatform.ANDROID,
            credential,
        )
        tourControlService.setGuestSocketFactory(null)
        assetTransferService.setGuestSocketFactory(null)
        tourControlService.startGuest(hostIP)
        assetTransferService.joinTour(hostIP)

        val plane = coordinator.selectAudioPlane()
        plane.configureSession(
            sessionID = sessionID,
            participantID = participantID,
            displayName = coordinator.controlPlane.localPeer.displayName,
            platform = ParticipantPlatform.ANDROID,
            credential = credential,
        )
        plane.setSessionEventHandler { event ->
            scope.launch { handleGuestAudioSessionEvent(event) }
        }
        if (plane is UDPAudioPlane) plane.hostIP = hostIP
        audioEngine.startPlayback()
        // The first delivered PCM buffer of this run proves the audio lane works again (DSCN-19).
        val awaitingFirstBuffer = AtomicBoolean(true)
        plane.startListening(channelID = channel.id) { pcm ->
            if (awaitingFirstBuffer.compareAndSet(true, false)) consecutiveAudioLaneFailures.set(0)
            audioEngine.enqueuePlayback(pcm)
        }
    }

    /**
     * Guest-side audio-lane events. Loss is a reconnect trigger with the same authority as
     * control-lane loss (ADR-044); [handleAudioSessionEvent] stays guide-only.
     */
    private fun handleGuestAudioSessionEvent(event: AudioSessionEvent) {
        if (_listenState.value != ListenState.LISTENING) return
        when (event) {
            is AudioSessionEvent.Joined, is AudioSessionEvent.Disconnected -> Unit // guide-side membership
            is AudioSessionEvent.VersionMismatch -> handleControlConnectionEvent(
                TourControlConnectionEvent.VersionMismatch(event.remoteMajor, event.localMajor),
            )
            is AudioSessionEvent.Failed -> {
                if (consecutiveAudioLaneFailures.incrementAndGet() >= 5) {
                    failGuestSession("Audio connection lost repeatedly")
                    return
                }
                handleControlConnectionEvent(TourControlConnectionEvent.Failed(event.message))
            }
        }
    }

    /** Terminal guest failure: the failed channel stays on screen with its reason. */
    private fun failGuestSession(message: String) {
        reconnectJob?.cancel()
        reconnectJob = null
        stopCurrentActivity()
        _connectionState.value = SessionConnectionState.FAILED
        _tourFeatureError.value = message
    }

    private fun handleControlConnectionEvent(event: TourControlConnectionEvent) {
        if (_listenState.value != ListenState.LISTENING) return
        when (event) {
            TourControlConnectionEvent.Connected -> {
                val route = activeGuestRoute ?: return
                if (!routeLease.select(route)) {
                    _connectionState.value = SessionConnectionState.FAILED
                    _tourFeatureError.value = "Session tried to activate two network routes"
                    return
                }
                reconnectJob?.cancel()
                reconnectJob = null
                _reconnectAttempt.value = 0
                _connectionState.value = SessionConnectionState.CONNECTED
                _tourFeatureError.value = null
            }
            TourControlConnectionEvent.Disconnected -> {
                if (_connectionState.value == SessionConnectionState.CONNECTED) {
                    scheduleReconnect("Guide connection closed")
                }
            }
            TourControlConnectionEvent.SessionEnded -> endGuestSessionFromGuide()
            is TourControlConnectionEvent.VersionMismatch ->
                failGuestSession(versionMismatchMessage(event.remoteMajor, event.localMajor))
            is TourControlConnectionEvent.CredentialRejected -> {
                // A wrong code cannot succeed on retry (FND-8): terminal, credentials erased.
                Log.e(TAG, "The guide rejected the tour code; not retrying")
                failGuestSession("The tour code was rejected. Check it with the guide.")
            }
            is TourControlConnectionEvent.Failed -> {
                val channel = activeChannel ?: return
                val credential = guestCredential ?: return
                val sessionID = runCatching { UUID.fromString(channel.id) }.getOrNull() ?: return
                val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }
                    .getOrNull() ?: return
                if (_connectionState.value == SessionConnectionState.CONNECTED) {
                    scheduleReconnect(event.message)
                } else {
                    failCurrentGuestRoute(channel, sessionID, participantID, credential, event.message)
                }
            }
        }
    }

    private fun failCurrentGuestRoute(
        channel: Channel,
        sessionID: UUID,
        participantID: UUID,
        credential: SessionCredential,
        reason: String,
    ) {
        coordinator.activeAudioPlane?.stop()
        tourControlService.stop()
        assetTransferService.stop()
        audioEngine.stopPlayback()
        _tourFeatureError.value = reason
        tryNextGuestRoute(channel, sessionID, participantID, credential)
    }

    private fun scheduleReconnect(reason: String) {
        if (reconnectJob != null) return
        if (_reconnectAttempt.value >= 5) {
            failGuestSession("Could not reconnect to the guide")
            return
        }
        val channel = activeChannel ?: return
        if (guestCredential == null) return
        _reconnectAttempt.value += 1
        _connectionState.value = SessionConnectionState.RECONNECTING
        _tourFeatureError.value = reason
        Log.e(TAG, "Session reconnect attempt ${_reconnectAttempt.value}")
        val delayMilliseconds = (1L shl (_reconnectAttempt.value - 1)) * reconnectBaseDelayMillis
        reconnectJob = scope.launch {
            delay(delayMilliseconds)
            reconnectJob = null
            if (_listenState.value != ListenState.LISTENING) return@launch
            // A fresher discovery address wins over the one captured when the reconnect was scheduled.
            restartGuestTransports(activeChannel ?: channel)
        }
    }

    /**
     * Stop + reconfigure of the guest lanes with the retained credential (FND-6, DSCN-11). Used by
     * the discovery address change and by the reconnect timer. Never joinChannel, never
     * clearSession, never a fresh credential stretch.
     */
    private fun restartGuestTransports(channel: Channel) {
        if (_listenState.value != ListenState.LISTENING) return
        val credential = guestCredential ?: run {
            Log.e(TAG, "Cannot restart guest transports without an admitted credential")
            return
        }
        val sessionID = runCatching { UUID.fromString(channel.id) }.getOrNull() ?: run {
            Log.e(TAG, "Cannot restart guest transports with a non-UUID channel identity")
            return
        }
        val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }.getOrNull() ?: run {
            Log.e(TAG, "Cannot restart guest transports with a non-UUID participant identity")
            return
        }
        reconnectJob?.cancel()
        reconnectJob = null
        coordinator.activeAudioPlane?.stop()
        tourControlService.stop()
        assetTransferService.stop()
        audioEngine.stopPlayback()
        attemptedGuestRoutes.clear()
        routeLease.reset()
        tryNextGuestRoute(channel, sessionID, participantID, credential)
    }

    private fun handleDiscoveryUnavailable(channelID: String) {
        if (_activeChannelID.value == channelID) {
            Log.i(TAG, "Active channel discovery became unavailable; data session remains authoritative")
            return
        }
        _channels.value = _channels.value.filter { it.id != channelID }
    }

    private fun endGuestSessionFromGuide() {
        val channelID = _activeChannelID.value ?: return
        stopCurrentActivity()
        _channels.value = _channels.value.filter { it.id != channelID }
        _activeChannelID.value = null
        _listenState.value = ListenState.IDLE
        _tourCode.value = null
        _connectionState.value = SessionConnectionState.IDLE
        guestCredential = null
        Log.i(TAG, "Authenticated guide ended the session")
    }

    private fun runPresentationAction(action: () -> Unit) {
        try {
            action()
            _tourFeatureError.value = null
        } catch (error: Exception) {
            _tourFeatureError.value = error.message ?: error.javaClass.simpleName
        }
    }
}
