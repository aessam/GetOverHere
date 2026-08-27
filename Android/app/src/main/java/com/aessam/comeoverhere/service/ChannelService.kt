package com.aessam.comeoverhere.service

import android.util.Log
import com.aessam.comeoverhere.core.*
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantRegistry
import com.aessam.toursession.PresentationSnapshotPayload
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TargetSnapshotPayload
import com.aessam.toursession.BearingSnapshotPayload
import com.aessam.toursession.TourVisualMode
import com.aessam.toursession.VisualFocusSnapshotPayload
import com.aessam.toursession.AwareSessionAnnouncement
import com.aessam.toursession.SessionRouteAvailability
import com.aessam.toursession.SessionRouteLease
import com.aessam.toursession.SessionTransportRoute
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.File
import java.util.UUID

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
    val listenerCount: StateFlow<Int>
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
    val connectionState: StateFlow<SessionConnectionState>
    val reconnectAttempt: StateFlow<Int>
    val targetSnapshot: StateFlow<TargetSnapshotPayload?>
    val bearingSnapshot: StateFlow<BearingSnapshotPayload?>
    val visualFocusSnapshot: StateFlow<VisualFocusSnapshotPayload?>
    val localGuidanceService: LocalGuidanceService
    val localPeerID: String
    val audioQuality: AudioQuality

    fun start()
    fun stop()
    fun enableWiFiAware()
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
    private val audioEngine: AudioEngine,
    private val scope: CoroutineScope,
    private val tourControlService: TourControlService,
    private val assetTransferService: TourAssetTransferService,
    private val contentStore: TourContentStore,
    override val localGuidanceService: LocalGuidanceService,
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

    private val _connectionState = MutableStateFlow(SessionConnectionState.IDLE)
    override val connectionState: StateFlow<SessionConnectionState> = _connectionState.asStateFlow()

    private val _reconnectAttempt = MutableStateFlow(0)
    override val reconnectAttempt: StateFlow<Int> = _reconnectAttempt.asStateFlow()

    override val connectedPeers: StateFlow<List<PeerInfo>> = coordinator.controlPlane.connectedPeers
    override val localPeerID: String get() = coordinator.controlPlane.localPeer.id
    override var audioQuality: AudioQuality = AudioQuality.STANDARD

    private var captureJob: Job? = null
    private var reconnectJob: Job? = null
    private var guestCredential: SessionCredential? = null
    private var participantRegistry = ParticipantRegistry()
    private var activeGuestRoute: SessionTransportRoute? = null
    private var awareGuestRoute: WiFiAwareSessionTransport.GuestRoute? = null
    private var attemptedGuestRoutes = mutableSetOf<SessionTransportRoute>()
    private var routeLease = SessionRouteLease()

    val activeChannel: Channel?
        get() = _channels.value.find { it.id == _activeChannelID.value }

    val isCreator: Boolean
        get() = activeChannel?.createdBy == coordinator.controlPlane.localPeer.id

    companion object {
        private const val TAG = "ChannelService"
    }

    init {
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
        listenForAwareAnnouncements()
        startPeriodicBroadcast()
        Log.i(TAG, "ChannelService started")
    }

    override fun stop() {
        stopCurrentActivity()
    }

    override fun enableWiFiAware() {
        coordinator.enableWiFiAware()
    }

    // MARK: - Channel Management

    override fun createChannel(name: String, quality: AudioQuality) {
        audioQuality = quality
        val channel = Channel(
            id = UUID.randomUUID().toString(),
            name = name,
            createdAt = nowAsSwiftRef(),
            createdBy = coordinator.controlPlane.localPeer.id,
            hasWiFiAware = coordinator.awareSnapshot.value.available,
        )
        val sessionID = UUID.fromString(channel.id)
        val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }
            .getOrElse {
                Log.e(TAG, "Cannot create session with non-UUID participant identity", it)
                return
            }
        try {
            val code = SessionCredential.generateShortCode()
            val credential = SessionCredential.derive(code, sessionID)
            contentStore.beginPack(sessionID, name)
            val emptyManifest = contentStore.manifestPayload()
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
            tourControlService.startGuide(sessionID)
            assetTransferService.startGuideWithEmptyTourPack(emptyManifest)
            _readySlideFiles.value = emptyMap()
            _offlineMapConfiguration.value = null
            _offlineMapStatus.value = OfflineMapStatus.Unavailable
            _tourFeatureError.value = null
            _tourCode.value = code

            _channels.value = _channels.value + channel
            _activeChannelID.value = channel.id
            _listenState.value = ListenState.BROADCASTING
            _connectionState.value = SessionConnectionState.CONNECTED
            guestCredential = null

            broadcastChannelAnnounce(channel)

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
            if (channel.hasWiFiAware) {
                coordinator.hostWiFiAware(
                    AwareSessionAnnouncement(
                        sessionID = sessionID,
                        guideID = participantID,
                        guidePlatform = ParticipantPlatform.ANDROID,
                        realtimePort = WiFiAwareSessionTransport.REALTIME_PORT,
                        controlPort = WiFiAwareSessionTransport.CONTROL_PORT,
                        assetPort = WiFiAwareSessionTransport.ASSET_PORT,
                        channelName = channel.name,
                        guideDisplayName = coordinator.controlPlane.localPeer.displayName,
                    ),
                )
            }
        } catch (error: Exception) {
            _tourCode.value = null
            _tourFeatureError.value = error.message ?: error.javaClass.simpleName
            Log.e(TAG, "Cannot start tour features (${error.javaClass.simpleName})")
            return
        }
        Log.i(TAG, "Created megaphone (quality: ${audioQuality.label})")
    }

    override fun joinChannel(channel: Channel, tourCode: String) {
        val sessionID = runCatching { UUID.fromString(channel.id) }
            .getOrElse {
                Log.e(TAG, "Cannot join session with non-UUID channel identity", it)
                return
            }
        val normalizedCode = SessionCredential.normalize(tourCode)
        val credential = runCatching { SessionCredential.derive(normalizedCode, sessionID) }
            .getOrElse {
                _tourFeatureError.value = it.message ?: it.javaClass.simpleName
                return
            }
        val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }
            .getOrElse {
                Log.e(TAG, "Cannot join session with non-UUID participant identity", it)
                return
            }
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
        awareGuestRoute = null
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
        val ch = activeChannel ?: return
        stopCurrentActivity()
        _activeChannelID.value = null
        _listenState.value = ListenState.IDLE
        _tourCode.value = null
        _connectionState.value = SessionConnectionState.IDLE
        guestCredential = null
        Log.i(TAG, "Left channel")

        if (ch.createdBy == coordinator.controlPlane.localPeer.id) {
            coordinator.stopWiFiAwareHosting()
            _channels.value = _channels.value.filter { it.id != ch.id }
            coordinator.controlPlane.broadcast(BLECommand.ChannelEnded(channelID = ch.id))
        }
    }

    // MARK: - Private

    private fun startCapturing(plane: AudioPlane, channelID: String) {
        captureJob = scope.launch {
            audioEngine.startCapture().collect { pcmData ->
                if (!isActive) return@collect
                plane.sendAudio(pcmData)
            }
        }
    }

    private fun stopCurrentActivity() {
        reconnectJob?.cancel()
        reconnectJob = null
        _reconnectAttempt.value = 0
        guestCredential = null
        if (_listenState.value == ListenState.BROADCASTING) {
            audioEngine.stopCapture()
            captureJob?.cancel()
            captureJob = null
        } else if (_listenState.value == ListenState.LISTENING) {
            audioEngine.stopPlayback()
        }
        coordinator.activeAudioPlane?.setSessionEventHandler(null)
        coordinator.activeAudioPlane?.stop()
        tourControlService.stop()
        assetTransferService.stop()
        localGuidanceService.stop()
        _offlineMapConfiguration.value = null
        _offlineMapStatus.value = OfflineMapStatus.Unavailable
        participantRegistry = ParticipantRegistry()
        _listenerCount.value = 0
        _readyParticipantCount.value = 0
        _connectionState.value = SessionConnectionState.IDLE
        activeGuestRoute = null
        awareGuestRoute = null
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
            audioHostIP = channel.audioHostIP
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
                                hasWiFiAware = existing.hasWiFiAware,
                            )
                            _channels.value = _channels.value.map {
                                if (it.id == command.channelID) updated else it
                            }
                            Log.i(TAG, "Updated discovered megaphone")

                            if (_activeChannelID.value == updated.id &&
                                _listenState.value == ListenState.LISTENING &&
                                existing.audioHostIP != updated.audioHostIP) {
                                _tourCode.value?.let { joinChannel(updated, it) }
                            }
                        } else {
                            val channel = Channel(
                                id = command.channelID,
                                name = command.channelName,
                                createdAt = nowAsSwiftRef(),
                                createdBy = command.createdBy,
                                audioHostIP = command.audioHostIP
                            )
                            _channels.value = _channels.value + channel
                            Log.i(TAG, "Discovered megaphone")
                        }
                    }
                    is BLECommand.ChannelEnded -> {
                        _channels.value = _channels.value.filter { it.id != command.channelID }
                        if (_activeChannelID.value == command.channelID) {
                            stopCurrentActivity()
                            _activeChannelID.value = null
                            _listenState.value = ListenState.IDLE
                            _tourCode.value = null
                            _connectionState.value = SessionConnectionState.IDLE
                            guestCredential = null
                            Log.i(TAG, "Channel ended")
                        }
                    }
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

    private fun listenForAwareAnnouncements() {
        scope.launch {
            coordinator.awareAnnouncements.collect { announcement ->
                val channelID = announcement.sessionID.toString()
                val existing = _channels.value.find { it.id.equals(channelID, ignoreCase = true) }
                val updated = if (existing == null) {
                    Channel(
                        id = channelID,
                        name = announcement.channelName,
                        createdAt = nowAsSwiftRef(),
                        createdBy = announcement.guideID.toString(),
                        audioHostIP = null,
                        hasWiFiAware = true,
                    )
                } else {
                    existing.copy(name = announcement.channelName, hasWiFiAware = true)
                }
                _channels.value = if (existing == null) {
                    _channels.value + updated
                } else {
                    _channels.value.map { if (it.id == existing.id) updated else it }
                }
                Log.i(TAG, "Discovered megaphone over Wi-Fi Aware")

                if (
                    updated.id.equals(_activeChannelID.value, ignoreCase = true) &&
                    _listenState.value == ListenState.LISTENING &&
                    _connectionState.value == SessionConnectionState.FAILED
                ) {
                    val credential = guestCredential ?: return@collect
                    val participantID = runCatching {
                        UUID.fromString(coordinator.controlPlane.localPeer.id)
                    }.getOrNull() ?: return@collect
                    attemptedGuestRoutes.clear()
                    routeLease.reset()
                    _connectionState.value = SessionConnectionState.CONNECTING
                    tryNextGuestRoute(updated, announcement.sessionID, participantID, credential)
                }
            }
        }
    }

    private fun handleAudioSessionEvent(event: AudioSessionEvent) {
        when (event) {
            is AudioSessionEvent.Joined -> participantRegistry.register(event.participant)
            is AudioSessionEvent.Disconnected -> participantRegistry.disconnect(event.connectionID)
            is AudioSessionEvent.VersionMismatch -> {
                _connectionState.value = SessionConnectionState.FAILED
                _tourFeatureError.value =
                    "Tour protocol version mismatch (remote ${event.remoteMajor}, local ${event.localMajor}). " +
                    "Update the older app."
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
        val available = SessionRouteAvailability(
            hasLANHost = channel.audioHostIP != null,
            hasWiFiAwareSession = channel.hasWiFiAware,
        ).orderedRoutes
        val preferred = activeGuestRoute?.takeIf(available::contains)
        val ordered = buildList {
            if (preferred != null) add(preferred)
            addAll(available)
        }.distinct()
        val route = ordered.firstOrNull { it !in attemptedGuestRoutes }
        if (route == null) {
            if (available.isEmpty()) {
                _connectionState.value = SessionConnectionState.FAILED
                _tourFeatureError.value = "No local LAN or Wi-Fi Aware route is available"
            } else {
                activeGuestRoute = null
                scheduleReconnect("Could not authenticate a route to the guide")
            }
            return
        }

        attemptedGuestRoutes += route
        activeGuestRoute = route
        _connectionState.value = SessionConnectionState.CONNECTING
        when (route) {
            SessionTransportRoute.LOCAL_LAN -> {
                val hostIP = channel.audioHostIP
                if (hostIP == null) {
                    tryNextGuestRoute(channel, sessionID, participantID, credential)
                    return
                }
                awareGuestRoute = null
                startGuestTransports(
                    channel,
                    hostIP,
                    sessionID,
                    participantID,
                    credential,
                    route,
                    null,
                )
            }
            SessionTransportRoute.WIFI_AWARE -> {
                coordinator.connectWiFiAware(sessionID) { result ->
                    scope.launch {
                        if (
                            _listenState.value != ListenState.LISTENING ||
                            _activeChannelID.value?.equals(channel.id, ignoreCase = true) != true ||
                            activeGuestRoute != SessionTransportRoute.WIFI_AWARE
                        ) return@launch
                        result.fold(
                            onSuccess = { awareRoute ->
                                awareGuestRoute = awareRoute
                                startGuestTransports(
                                    channel,
                                    awareRoute.guideHost,
                                    sessionID,
                                    participantID,
                                    credential,
                                    route,
                                    awareRoute,
                                )
                            },
                            onFailure = { error ->
                                failCurrentGuestRoute(
                                    channel,
                                    sessionID,
                                    participantID,
                                    credential,
                                    error.message ?: error.javaClass.simpleName,
                                )
                            },
                        )
                    }
                }
            }
        }
    }

    private fun startGuestTransports(
        channel: Channel,
        hostIP: String,
        sessionID: UUID,
        participantID: UUID,
        credential: SessionCredential,
        route: SessionTransportRoute,
        awareRoute: WiFiAwareSessionTransport.GuestRoute?,
    ) {
        val socketFactory = if (route == SessionTransportRoute.WIFI_AWARE) {
            requireNotNull(awareRoute) { "Wi-Fi Aware route is missing its Android Network" }
                .network.socketFactory
        } else {
            null
        }
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
        tourControlService.setGuestSocketFactory(socketFactory)
        assetTransferService.setGuestSocketFactory(socketFactory)
        tourControlService.startGuest(hostIP)
        assetTransferService.joinTour(hostIP)

        val plane = coordinator.selectAudioPlane(route, awareRoute)
        plane.configureSession(
            sessionID = sessionID,
            participantID = participantID,
            displayName = coordinator.controlPlane.localPeer.displayName,
            platform = ParticipantPlatform.ANDROID,
            credential = credential,
        )
        plane.setSessionEventHandler(null)
        if (plane is UDPAudioPlane) plane.hostIP = hostIP
        audioEngine.startPlayback()
        plane.startListening(channelID = channel.id, audioEngine::enqueuePlayback)
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
            is TourControlConnectionEvent.VersionMismatch -> {
                reconnectJob?.cancel()
                reconnectJob = null
                _connectionState.value = SessionConnectionState.FAILED
                _tourFeatureError.value =
                    "Tour protocol version mismatch (remote ${event.remoteMajor}, local ${event.localMajor}). " +
                    "Update the older app."
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
        awareGuestRoute = null
        _tourFeatureError.value = reason
        tryNextGuestRoute(channel, sessionID, participantID, credential)
    }

    private fun scheduleReconnect(reason: String) {
        if (reconnectJob != null) return
        if (_reconnectAttempt.value >= 5) {
            _connectionState.value = SessionConnectionState.FAILED
            _tourFeatureError.value = "Could not reconnect to the guide"
            return
        }
        val channel = activeChannel ?: return
        val credential = guestCredential ?: return
        val sessionID = runCatching { UUID.fromString(channel.id) }.getOrNull() ?: return
        val participantID = runCatching { UUID.fromString(coordinator.controlPlane.localPeer.id) }
            .getOrNull() ?: return
        _reconnectAttempt.value += 1
        _connectionState.value = SessionConnectionState.RECONNECTING
        _tourFeatureError.value = reason
        Log.e(TAG, "Session reconnect attempt ${_reconnectAttempt.value}")
        val delayMilliseconds = (1L shl (_reconnectAttempt.value - 1)) * 1_000L
        reconnectJob = scope.launch {
            delay(delayMilliseconds)
            reconnectJob = null
            if (_listenState.value != ListenState.LISTENING) return@launch
            coordinator.activeAudioPlane?.stop()
            tourControlService.stop()
            assetTransferService.stop()
            audioEngine.stopPlayback()
            attemptedGuestRoutes.clear()
            routeLease.reset()
            awareGuestRoute = null
            tryNextGuestRoute(channel, sessionID, participantID, credential)
        }
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
