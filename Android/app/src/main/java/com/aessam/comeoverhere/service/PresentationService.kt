package com.aessam.comeoverhere.service

import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionControlTransport
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.PresentationSnapshotPayload
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import com.aessam.toursession.TargetSnapshotPayload
import com.aessam.toursession.BearingSnapshotPayload
import com.aessam.toursession.BearingReference
import com.aessam.toursession.TourVisualMode
import com.aessam.toursession.VisualFocusSnapshotPayload
import com.aessam.toursession.AudioReadinessPayload
import com.aessam.toursession.AudioReadinessStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import kotlin.math.roundToInt
import javax.net.SocketFactory

enum class PresentationServiceRole { GUIDE, GUEST }

sealed class TourControlConnectionEvent {
    data class AuthenticationFailed(val message: String) : TourControlConnectionEvent()
    data object Connected : TourControlConnectionEvent()
    data object Disconnected : TourControlConnectionEvent()
    data object SessionEnded : TourControlConnectionEvent()
    data class VersionMismatch(val remoteMajor: Int, val localMajor: Int) : TourControlConnectionEvent()
    /** The guide rejected the tour code; terminal, never retried (FND-8). */
    data class CredentialRejected(val message: String) : TourControlConnectionEvent()
    data class Failed(val message: String) : TourControlConnectionEvent()
}

class PresentationServiceException(message: String) : IllegalStateException(message)

class TourControlService(
    private val transport: SessionControlTransport = LocalSessionControlTransport(),
) {
    fun configureGuideAuthentication(authentication: com.aessam.comeoverhere.core.SessionGuideAuthentication) =
        transport.configureGuideAuthentication(authentication)
    private val mutableSnapshot = MutableStateFlow<PresentationSnapshotPayload?>(null)
    val snapshot: StateFlow<PresentationSnapshotPayload?> = mutableSnapshot.asStateFlow()

    private val mutableSlides = MutableStateFlow<List<TourAssetDescriptor>>(emptyList())
    val slides: StateFlow<List<TourAssetDescriptor>> = mutableSlides.asStateFlow()

    private val mutableLastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = mutableLastError.asStateFlow()

    private val mutableTargetSnapshot = MutableStateFlow<TargetSnapshotPayload?>(null)
    val targetSnapshot: StateFlow<TargetSnapshotPayload?> = mutableTargetSnapshot.asStateFlow()

    private val mutableBearingSnapshot = MutableStateFlow<BearingSnapshotPayload?>(null)
    val bearingSnapshot: StateFlow<BearingSnapshotPayload?> = mutableBearingSnapshot.asStateFlow()

    private val mutableVisualFocusSnapshot = MutableStateFlow<VisualFocusSnapshotPayload?>(null)
    val visualFocusSnapshot: StateFlow<VisualFocusSnapshotPayload?> = mutableVisualFocusSnapshot.asStateFlow()

    /** Guests admitted on the control lane, keyed by participant (FND-13); independent of audio readiness. */
    private val mutableConnectedGuestCount = MutableStateFlow(0)
    val connectedGuestCount: StateFlow<Int> = mutableConnectedGuestCount.asStateFlow()
    private val connectedGuestIDs = mutableSetOf<UUID>()
    private val guestAudioReports = mutableMapOf<UUID, AudioReadinessPayload>()
    private val mutableAudioReadyGuestCount = MutableStateFlow(0)
    val audioReadyGuestCount = mutableAudioReadyGuestCount.asStateFlow()

    fun reportGuestAudio(status: AudioReadinessStatus, revision: ULong) {
        if (role != PresentationServiceRole.GUEST || !transport.isActive) return
        transport.send(SessionMessageKind.AUDIO_STATUS, AudioReadinessPayload(status, revision).encode())
    }

    private var role: PresentationServiceRole? = null
    private var sessionID: UUID? = null
    private var runGeneration = 0L
    private var connectionEventHandler: ((TourControlConnectionEvent) -> Unit)? = null

    val currentSlideID: String? get() = mutableSnapshot.value?.currentSlideID
    val isVisible: Boolean get() = mutableSnapshot.value?.isVisible == true

    val currentSlideIndex: Int?
        get() = currentSlideID?.let { id -> mutableSlides.value.indexOfFirst { it.assetID == id } }
            ?.takeIf { it >= 0 }

    val canGoPrevious: Boolean get() = (currentSlideIndex ?: 0) > 0
    val canGoNext: Boolean
        get() = currentSlideIndex?.let { it < mutableSlides.value.lastIndex } == true

    init {
        installTransportHandler()
    }

    private fun installTransportHandler() {
        val generation = runGeneration
        transport.setEventHandler { event ->
            synchronized(this) { if (generation == runGeneration) handle(event) }
        }
    }

    fun setConnectionEventHandler(handler: ((TourControlConnectionEvent) -> Unit)?) {
        connectionEventHandler = handler
    }

    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {
        stop()
        synchronized(this) {
            this.sessionID = sessionID
            installTransportHandler()
        }
        transport.configureSession(sessionID, participantID, displayName, platform, credential)
    }

    fun startGuide(deckID: UUID, slides: List<TourAssetDescriptor> = emptyList()) {
        role = PresentationServiceRole.GUIDE
        mutableSlides.value = orderedSlides(slides)
        mutableSnapshot.value = PresentationSnapshotPayload(
            stateVersion = 0,
            deckID = deckID,
            currentSlideID = mutableSlides.value.firstOrNull()?.assetID,
            isVisible = false,
            effectiveAtMilliseconds = System.currentTimeMillis(),
        )
        mutableVisualFocusSnapshot.value = VisualFocusSnapshotPayload(0, TourVisualMode.SLIDES)
        transport.startGuide()
    }

    fun startGuest(hostIP: String) {
        role = PresentationServiceRole.GUEST
        transport.hostIP = hostIP
        transport.startGuest()
    }

    /** Flushes the authenticated leave without blocking the caller's thread (FND-8). */
    suspend fun endGuideSession() {
        requireGuide()
        transport.sendLeave()
    }

    fun setGuestSocketFactory(factory: SocketFactory?) {
        transport.setGuestSocketFactory(factory)
    }

    fun updateDeck(deckID: UUID, slides: List<TourAssetDescriptor>) {
        requireGuide()
        val ordered = orderedSlides(slides)
        val currentID = mutableSnapshot.value?.currentSlideID
        mutableSlides.value = ordered
        val selectedID = currentID?.takeIf { id -> ordered.any { it.assetID == id } }
            ?: ordered.firstOrNull()?.assetID
        publish(
            deckID,
            selectedID,
            mutableSnapshot.value?.isVisible == true && selectedID != null,
        )
    }

    fun acceptTourPack(manifest: TourPackManifestPayload) {
        if (role != PresentationServiceRole.GUEST) return
        mutableSlides.value = orderedSlides(manifest.assets)
    }

    fun showSlide(assetID: String? = null) {
        requireGuide()
        val deckID = mutableSnapshot.value?.deckID ?: sessionID ?: return
        val selectedID = assetID ?: mutableSnapshot.value?.currentSlideID
            ?: mutableSlides.value.firstOrNull()?.assetID
        if (selectedID != null && mutableSlides.value.none { it.assetID == selectedID }) {
            throw PresentationServiceException("Unknown slide asset ID $selectedID")
        }
        publish(deckID, selectedID, selectedID != null)
        ensureVisualFocus(TourVisualMode.SLIDES)
    }

    fun hide() {
        requireGuide()
        val current = mutableSnapshot.value ?: return
        publish(current.deckID, current.currentSlideID, false)
    }

    fun goPrevious() = move(-1)

    fun goNext() = move(1)

    fun setTarget(latitude: Double, longitude: Double, label: String = "") {
        requireGuide()
        val next = TargetSnapshotPayload(
            stateVersion = (mutableTargetSnapshot.value?.stateVersion ?: 0) + 1,
            targetID = mutableTargetSnapshot.value?.targetID ?: UUID.randomUUID(),
            latitudeE7 = coordinateE7(latitude, -900_000_000..900_000_000, "latitude"),
            longitudeE7 = coordinateE7(longitude, -1_800_000_000..1_800_000_000, "longitude"),
            label = label.take(256),
            isVisible = true,
        )
        mutableTargetSnapshot.value = next
        transport.send(SessionMessageKind.TARGET_SNAPSHOT, next.encode())
        ensureVisualFocus(TourVisualMode.MAP)
    }

    fun clearTarget() {
        requireGuide()
        val current = mutableTargetSnapshot.value ?: return
        val next = TargetSnapshotPayload(
            current.stateVersion + 1,
            current.targetID,
            current.latitudeE7,
            current.longitudeE7,
            current.label,
            false,
        )
        mutableTargetSnapshot.value = next
        transport.send(SessionMessageKind.TARGET_SNAPSHOT, next.encode())
    }

    fun shareBearing(degrees: Double) {
        requireGuide()
        if (!degrees.isFinite() || degrees !in 0.0..<360.0) {
            throw PresentationServiceException("A valid compass heading is required")
        }
        val next = BearingSnapshotPayload(
            stateVersion = (mutableBearingSnapshot.value?.stateVersion ?: 0) + 1,
            reference = BearingReference.MAGNETIC,
            bearingMilliDegrees = (degrees * 1_000).roundToInt().toLong(),
            isVisible = true,
        )
        mutableBearingSnapshot.value = next
        transport.send(SessionMessageKind.BEARING_SNAPSHOT, next.encode())
        ensureVisualFocus(TourVisualMode.POINTER)
    }

    fun setVisualFocus(mode: TourVisualMode) {
        requireGuide()
        publishVisualFocus(mode)
    }

    fun clearBearing() {
        requireGuide()
        val current = mutableBearingSnapshot.value ?: return
        val next = BearingSnapshotPayload(
            current.stateVersion + 1,
            current.reference,
            current.bearingMilliDegrees,
            false,
        )
        mutableBearingSnapshot.value = next
        transport.send(SessionMessageKind.BEARING_SNAPSHOT, next.encode())
    }

    fun stop() {
        synchronized(this) {
            runGeneration++
            role = null
            sessionID = null
            mutableSnapshot.value = null
            mutableTargetSnapshot.value = null
            mutableBearingSnapshot.value = null
            mutableVisualFocusSnapshot.value = null
            mutableSlides.value = emptyList()
            mutableLastError.value = null
            synchronized(connectedGuestIDs) {
                connectedGuestIDs.clear()
                guestAudioReports.clear()
                mutableAudioReadyGuestCount.value = 0
                mutableConnectedGuestCount.value = 0
            }
        }
        // Native close can complete a callback: never hold the service lock across it.
        transport.stop()
    }

    private fun recordGuestJoined(participantID: UUID) {
        synchronized(connectedGuestIDs) {
            connectedGuestIDs += participantID
            guestAudioReports.remove(participantID)
            updateAudioReadyCount()
            mutableConnectedGuestCount.value = connectedGuestIDs.size
        }
    }

    private fun recordGuestDisconnected(participantID: UUID) {
        synchronized(connectedGuestIDs) {
            connectedGuestIDs -= participantID
            guestAudioReports.remove(participantID)
            updateAudioReadyCount()
            mutableConnectedGuestCount.value = connectedGuestIDs.size
        }
    }

    /** Called only under the membership lock, after an authenticated control-lane report. */
    private fun updateAudioReadyCount() {
        mutableAudioReadyGuestCount.value = guestAudioReports.count { (id, report) ->
            id in connectedGuestIDs && report.status == AudioReadinessStatus.PLAYING
        }
    }

    private fun acceptAudioReport(envelope: com.aessam.toursession.SessionEnvelope) {
        synchronized(connectedGuestIDs) {
            if (envelope.sessionId != sessionID || envelope.senderId !in connectedGuestIDs) return
            val incoming = AudioReadinessPayload.decode(envelope.payload)
            val previous = guestAudioReports[envelope.senderId]
            if (previous != null && incoming.revision <= previous.revision) return
            guestAudioReports[envelope.senderId] = incoming
            updateAudioReadyCount()
        }
    }

    fun clearSession() {
        stop()
        transport.clearSession()
    }

    private fun move(offset: Int) {
        requireGuide()
        val ordered = mutableSlides.value
        if (ordered.isEmpty()) return
        val current = currentSlideIndex ?: 0
        val destination = (current + offset).coerceIn(0, ordered.lastIndex)
        showSlide(ordered[destination].assetID)
    }

    private fun requireGuide() {
        if (role != PresentationServiceRole.GUIDE) {
            throw PresentationServiceException("Only the guide can change the presentation")
        }
    }

    private fun publish(deckID: UUID, slideID: String?, isVisible: Boolean) {
        val next = PresentationSnapshotPayload(
            stateVersion = (mutableSnapshot.value?.stateVersion ?: 0) + 1,
            deckID = deckID,
            currentSlideID = slideID,
            isVisible = isVisible,
            effectiveAtMilliseconds = System.currentTimeMillis(),
        )
        mutableSnapshot.value = next
        transport.send(SessionMessageKind.PRESENTATION_SNAPSHOT, next.encode())
    }

    private fun ensureVisualFocus(mode: TourVisualMode) {
        if (mutableVisualFocusSnapshot.value?.mode != mode) publishVisualFocus(mode)
    }

    private fun publishVisualFocus(mode: TourVisualMode) {
        val next = VisualFocusSnapshotPayload(
            (mutableVisualFocusSnapshot.value?.stateVersion ?: 0) + 1,
            mode,
        )
        mutableVisualFocusSnapshot.value = next
        transport.send(SessionMessageKind.VISUAL_FOCUS_SNAPSHOT, next.encode())
    }

    private fun handle(event: SessionControlEvent) {
        when (event) {
            SessionControlEvent.Connected -> connectionEventHandler?.invoke(TourControlConnectionEvent.Connected)
            SessionControlEvent.Disconnected -> connectionEventHandler?.invoke(TourControlConnectionEvent.Disconnected)
            is SessionControlEvent.GuestJoined -> {
                if (role == PresentationServiceRole.GUIDE) {
                    recordGuestJoined(event.participant.participantId)
                    mutableSnapshot.value?.let { current ->
                        runCatching {
                            transport.send(SessionMessageKind.PRESENTATION_SNAPSHOT, current.encode())
                        }.onFailure(::report)
                    }
                    mutableTargetSnapshot.value?.let { current ->
                        runCatching {
                            transport.send(SessionMessageKind.TARGET_SNAPSHOT, current.encode())
                        }.onFailure(::report)
                    }
                    mutableBearingSnapshot.value?.let { current ->
                        runCatching {
                            transport.send(SessionMessageKind.BEARING_SNAPSHOT, current.encode())
                        }.onFailure(::report)
                    }
                    mutableVisualFocusSnapshot.value?.let { current ->
                        runCatching {
                            transport.send(SessionMessageKind.VISUAL_FOCUS_SNAPSHOT, current.encode())
                        }.onFailure(::report)
                    }
                }
            }
            is SessionControlEvent.EnvelopeReceived -> {
                if (event.envelope.sessionId != sessionID) return
                if (role == PresentationServiceRole.GUIDE && event.envelope.kind == SessionMessageKind.AUDIO_STATUS) {
                    runCatching { acceptAudioReport(event.envelope) }.onFailure(::report)
                    return
                }
                if (role != PresentationServiceRole.GUEST) return
                runCatching {
                    when (event.envelope.kind) {
                        SessionMessageKind.LEAVE -> {
                            connectionEventHandler?.invoke(TourControlConnectionEvent.SessionEnded)
                        }
                        SessionMessageKind.PRESENTATION_SNAPSHOT -> {
                            val incoming = PresentationSnapshotPayload.decode(event.envelope.payload)
                            val current = mutableSnapshot.value
                            if (current == null || incoming.stateVersion > current.stateVersion) {
                                mutableSnapshot.value = incoming
                            }
                        }
                        SessionMessageKind.TARGET_SNAPSHOT -> {
                            val incoming = TargetSnapshotPayload.decode(event.envelope.payload)
                            val current = mutableTargetSnapshot.value
                            if (current == null || incoming.stateVersion > current.stateVersion) {
                                mutableTargetSnapshot.value = incoming
                            }
                        }
                        SessionMessageKind.BEARING_SNAPSHOT -> {
                            val incoming = BearingSnapshotPayload.decode(event.envelope.payload)
                            val current = mutableBearingSnapshot.value
                            if (current == null || incoming.stateVersion > current.stateVersion) {
                                mutableBearingSnapshot.value = incoming
                            }
                        }
                        SessionMessageKind.VISUAL_FOCUS_SNAPSHOT -> {
                            val incoming = VisualFocusSnapshotPayload.decode(event.envelope.payload)
                            val current = mutableVisualFocusSnapshot.value
                            if (current == null || incoming.stateVersion > current.stateVersion) {
                                mutableVisualFocusSnapshot.value = incoming
                            }
                        }
                        else -> throw PresentationServiceException(
                            "Unexpected control-channel message ${event.envelope.kind.wireName}",
                        )
                    }
                }.onFailure(::report)
            }
            is SessionControlEvent.GuestDisconnected -> recordGuestDisconnected(event.participantID)
            is SessionControlEvent.VersionMismatch -> {
                val message = versionMismatchMessage(event.remoteMajor, event.localMajor)
                report(message)
                connectionEventHandler?.invoke(
                    TourControlConnectionEvent.VersionMismatch(event.remoteMajor, event.localMajor),
                )
            }
            is SessionControlEvent.CredentialRejected -> {
                report(event.message)
                connectionEventHandler?.invoke(TourControlConnectionEvent.CredentialRejected(event.message))
            }
            is SessionControlEvent.AuthenticationFailed -> {
                report(event.message)
                connectionEventHandler?.invoke(TourControlConnectionEvent.AuthenticationFailed(event.message))
            }
            is SessionControlEvent.Failed -> {
                report(event.message)
                connectionEventHandler?.invoke(TourControlConnectionEvent.Failed(event.message))
            }
        }
    }

    private fun report(error: Throwable) {
        report(error.message ?: error.javaClass.simpleName)
    }

    private fun report(message: String) {
        mutableLastError.value = message
    }

    private fun orderedSlides(assets: List<TourAssetDescriptor>): List<TourAssetDescriptor> =
        assets.filter { it.kind == TourAssetKind.SLIDE }
            .sortedWith(compareBy<TourAssetDescriptor> { it.order }.thenBy { it.assetID })

    private fun versionMismatchMessage(remoteMajor: Int, localMajor: Int): String =
        "Tour protocol version mismatch (remote $remoteMajor, local $localMajor). Update the older app."

    private fun coordinateE7(value: Double, range: IntRange, name: String): Int {
        val scaled = value * 10_000_000
        if (!scaled.isFinite() || scaled < range.first || scaled > range.last) {
            throw PresentationServiceException("Invalid $name $value")
        }
        return scaled.roundToInt()
    }
}
