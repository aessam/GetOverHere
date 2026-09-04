package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionControlTransport
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.parseBLECommand
import com.aessam.comeoverhere.core.toJson
import com.aessam.comeoverhere.service.TourControlService
import com.aessam.comeoverhere.service.TourControlConnectionEvent
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.PresentationSnapshotPayload
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TargetSnapshotPayload
import com.aessam.toursession.TourVisualMode
import com.aessam.toursession.VisualFocusSnapshotPayload
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class PresentationServiceTest {
    @Test
    fun guideLateJoinRestoresPresentationTargetPinAndPointerSnapshots() {
        val transport = RecordingControlTransport()
        val service = TourControlService(transport)
        val sessionID = UUID.randomUUID()
        val deckID = UUID.randomUUID()
        service.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guide",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        service.startGuide(deckID, listOf(slide("court", 1), slide("gate", 0)))
        service.showSlide()
        service.goNext()
        service.setTarget(37.176_128_4, -3.588_141_2, "Main Gate")
        service.shareBearing(271.25)

        assertEquals("court", service.currentSlideID)
        assertTrue(service.isVisible)

        assertEquals(2L, service.snapshot.value?.stateVersion)
        assertEquals(
            listOf(
                SessionMessageKind.PRESENTATION_SNAPSHOT,
                SessionMessageKind.PRESENTATION_SNAPSHOT,
                SessionMessageKind.TARGET_SNAPSHOT,
                SessionMessageKind.VISUAL_FOCUS_SNAPSHOT,
                SessionMessageKind.BEARING_SNAPSHOT,
                SessionMessageKind.VISUAL_FOCUS_SNAPSHOT,
            ),
            transport.sent.map { it.first },
        )

        transport.emit(
            SessionControlEvent.GuestJoined(
                ParticipantSession(
                    UUID.randomUUID(),
                    "guest-1",
                    "Guest",
                    SessionRole.GUEST,
                    ParticipantPlatform.IOS,
                ),
            ),
        )

        assertEquals(10, transport.sent.size)
        assertEquals(
            service.snapshot.value,
            PresentationSnapshotPayload.decode(transport.sent[6].second),
        )
        assertEquals(
            service.targetSnapshot.value,
            TargetSnapshotPayload.decode(transport.sent[7].second),
        )
        assertEquals(
            service.bearingSnapshot.value,
            com.aessam.toursession.BearingSnapshotPayload.decode(transport.sent[8].second),
        )
        assertEquals(
            service.visualFocusSnapshot.value,
            com.aessam.toursession.VisualFocusSnapshotPayload.decode(transport.sent[9].second),
        )
        assertEquals(com.aessam.toursession.TourVisualMode.POINTER, service.visualFocusSnapshot.value?.mode)
    }

    @Test
    fun guestIgnoresStalePresentationSnapshots() {
        val transport = RecordingControlTransport()
        val service = TourControlService(transport)
        val sessionID = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val deckID = UUID.randomUUID()
        service.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guest",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        service.startGuest("127.0.0.1")

        transport.emitSnapshot(
            PresentationSnapshotPayload(4, deckID, "court", true, 400),
            sessionID,
            guideID,
        )
        transport.emitSnapshot(
            PresentationSnapshotPayload(3, deckID, "gate", false, 300),
            sessionID,
            guideID,
        )

        assertEquals(4L, service.snapshot.value?.stateVersion)
        assertEquals("court", service.currentSlideID)
        assertTrue(service.isVisible)

        transport.emitTarget(
            TargetSnapshotPayload(
                8,
                UUID.randomUUID(),
                371_700_000,
                -31_880_000,
                "Main Gate",
                true,
            ),
            sessionID,
            guideID,
        )
        transport.emitTarget(
            TargetSnapshotPayload(7, UUID.randomUUID(), 0, 0, "Stale", false),
            sessionID,
            guideID,
        )
        assertEquals(8L, service.targetSnapshot.value?.stateVersion)
        assertEquals("Main Gate", service.targetSnapshot.value?.label)

        transport.emitVisualFocus(
            VisualFocusSnapshotPayload(6, TourVisualMode.POINTER),
            sessionID,
            guideID,
        )
        transport.emitVisualFocus(
            VisualFocusSnapshotPayload(5, TourVisualMode.MAP),
            sessionID,
            guideID,
        )
        assertEquals(6L, service.visualFocusSnapshot.value?.stateVersion)
        assertEquals(TourVisualMode.POINTER, service.visualFocusSnapshot.value?.mode)
    }

    @Test
    fun guidePublishesOnlySelectedTargetCoordinates() {
        val transport = RecordingControlTransport()
        val service = TourControlService(transport)
        val sessionID = UUID.randomUUID()
        service.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guide",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        service.startGuide(UUID.randomUUID())

        service.setTarget(37.176_128_4, -3.588_141_2, "Main Gate")

        assertEquals(2, transport.sent.size)
        assertEquals(SessionMessageKind.TARGET_SNAPSHOT, transport.sent[0].first)
        val target = TargetSnapshotPayload.decode(transport.sent[0].second)
        assertEquals(371_761_284, target.latitudeE7)
        assertEquals(-35_881_412, target.longitudeE7)
        assertEquals("Main Gate", target.label)
        assertEquals(SessionMessageKind.VISUAL_FOCUS_SNAPSHOT, transport.sent[1].first)
        assertEquals(
            com.aessam.toursession.TourVisualMode.MAP,
            com.aessam.toursession.VisualFocusSnapshotPayload.decode(transport.sent[1].second).mode,
        )
    }

    @Test
    fun guidePublishesAndClearsMagneticPointer() {
        val transport = RecordingControlTransport()
        val service = TourControlService(transport)
        val sessionID = UUID.randomUUID()
        service.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guide",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        service.startGuide(UUID.randomUUID())

        service.shareBearing(271.25)
        service.clearBearing()

        assertEquals(
            listOf(
                SessionMessageKind.BEARING_SNAPSHOT,
                SessionMessageKind.VISUAL_FOCUS_SNAPSHOT,
                SessionMessageKind.BEARING_SNAPSHOT,
            ),
            transport.sent.map { it.first },
        )
        val shown = com.aessam.toursession.BearingSnapshotPayload.decode(transport.sent[0].second)
        val hidden = com.aessam.toursession.BearingSnapshotPayload.decode(transport.sent[2].second)
        assertEquals(com.aessam.toursession.BearingReference.MAGNETIC, shown.reference)
        assertEquals(271_250L, shown.bearingMilliDegrees)
        assertTrue(shown.isVisible)
        assertTrue(!hidden.isVisible)
        assertEquals(shown.stateVersion + 1, hidden.stateVersion)
        assertEquals(
            com.aessam.toursession.TourVisualMode.POINTER,
            com.aessam.toursession.VisualFocusSnapshotPayload.decode(transport.sent[1].second).mode,
        )
    }

    @Test
    fun authenticatedLeaveDistinguishesSessionEndFromDiscoveryLoss() {
        val sessionID = UUID.randomUUID()
        val guideTransport = RecordingControlTransport()
        val guide = TourControlService(guideTransport)
        guide.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guide",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        guide.startGuide(UUID.randomUUID())
        runBlocking { guide.endGuideSession() }
        assertEquals(1, guideTransport.leaveFlushCount)
        assertEquals(SessionMessageKind.LEAVE, guideTransport.sent.last().first)
        assertTrue(guideTransport.sent.last().second.isEmpty())

        val guestTransport = RecordingControlTransport()
        val guest = TourControlService(guestTransport)
        val events = mutableListOf<TourControlConnectionEvent>()
        guest.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guest",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        guest.setConnectionEventHandler(events::add)
        guest.startGuest("127.0.0.1")
        guestTransport.emit(
            SessionControlEvent.EnvelopeReceived(
                SessionEnvelope(
                    majorVersion = SessionEnvelope.MAJOR_VERSION,
                    minorVersion = SessionEnvelope.MINOR_VERSION,
                    lane = SessionLane.CONTROL,
                    kind = SessionMessageKind.LEAVE,
                    flags = 0,
                    sequence = 9,
                    sessionId = sessionID,
                    senderId = UUID.randomUUID(),
                    payload = byteArrayOf(),
                ),
            ),
        )
        assertEquals(listOf(TourControlConnectionEvent.SessionEnded), events)
    }

    @Test
    fun connectedGuestCountFollowsControlLaneMembership() {
        val transport = RecordingControlTransport()
        val service = TourControlService(transport)
        val sessionID = UUID.randomUUID()
        service.configureSession(
            sessionID,
            UUID.randomUUID(),
            "Guide",
            ParticipantPlatform.ANDROID,
            presentationCredential(sessionID),
        )
        service.startGuide(UUID.randomUUID())
        val guestA = UUID.randomUUID()
        val guestB = UUID.randomUUID()

        transport.emit(SessionControlEvent.GuestJoined(participant(guestA, "a-1")))
        transport.emit(SessionControlEvent.GuestJoined(participant(guestB, "b-1")))
        assertEquals(2, service.connectedGuestCount.value)

        transport.emit(SessionControlEvent.GuestDisconnected(guestA))
        assertEquals(1, service.connectedGuestCount.value)
        transport.emit(SessionControlEvent.GuestDisconnected(guestA))
        assertEquals("disconnect is idempotent", 1, service.connectedGuestCount.value)

        // A re-registering guest arrives as disconnect + join and must count once (set semantics).
        transport.emit(SessionControlEvent.GuestDisconnected(guestB))
        transport.emit(SessionControlEvent.GuestJoined(participant(guestB, "b-2")))
        assertEquals(1, service.connectedGuestCount.value)

        service.stop()
        assertEquals(0, service.connectedGuestCount.value)
    }

    private fun participant(id: UUID, connectionID: String) = ParticipantSession(
        id,
        connectionID,
        "Guest",
        SessionRole.GUEST,
        ParticipantPlatform.IOS,
    )

    @Test
    fun discoveryUnavailableRoundtripsSeparatelyFromSessionEnd() {
        val channelID = UUID.randomUUID().toString()
        val decoded = parseBLECommand(BLECommand.ChannelUnavailable(channelID).toJson())
        assertEquals(BLECommand.ChannelUnavailable(channelID), decoded)
    }

    private fun slide(id: String, order: Long) = TourAssetDescriptor(
        id,
        TourAssetKind.SLIDE,
        if (order == 0L) "ab".repeat(32) else "cd".repeat(32),
        100,
        order,
        "image/jpeg",
    )
}

private class RecordingControlTransport : SessionControlTransport {
    override var isActive = false
        private set
    override var hostIP: String? = null
    var handler: ((SessionControlEvent) -> Unit)? = null
    val sent = mutableListOf<Pair<SessionMessageKind, ByteArray>>()
    var leaveFlushCount = 0

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) = Unit

    override fun setEventHandler(handler: ((SessionControlEvent) -> Unit)?) {
        this.handler = handler
    }

    override fun startGuide() { isActive = true }
    override fun startGuest() { isActive = true }

    override fun send(kind: SessionMessageKind, payload: ByteArray) {
        sent += kind to payload
    }

    override suspend fun sendLeave() {
        leaveFlushCount += 1
        sent += SessionMessageKind.LEAVE to byteArrayOf()
    }

    override fun stop() { isActive = false }
    override fun clearSession() = stop()

    fun emit(event: SessionControlEvent) = handler?.invoke(event)

    fun emitSnapshot(
        snapshot: PresentationSnapshotPayload,
        sessionID: UUID,
        guideID: UUID,
    ) {
        emit(
            SessionControlEvent.EnvelopeReceived(
                SessionEnvelope(
                    lane = SessionLane.CONTROL,
                    kind = SessionMessageKind.PRESENTATION_SNAPSHOT,
                    sequence = snapshot.stateVersion,
                    sessionId = sessionID,
                    senderId = guideID,
                    payload = snapshot.encode(),
                ),
            ),
        )
    }

    fun emitTarget(target: TargetSnapshotPayload, sessionID: UUID, guideID: UUID) {
        emit(
            SessionControlEvent.EnvelopeReceived(
                SessionEnvelope(
                    lane = SessionLane.CONTROL,
                    kind = SessionMessageKind.TARGET_SNAPSHOT,
                    sequence = target.stateVersion,
                    sessionId = sessionID,
                    senderId = guideID,
                    payload = target.encode(),
                ),
            ),
        )
    }

    fun emitVisualFocus(focus: VisualFocusSnapshotPayload, sessionID: UUID, guideID: UUID) {
        emit(
            SessionControlEvent.EnvelopeReceived(
                SessionEnvelope(
                    lane = SessionLane.CONTROL,
                    kind = SessionMessageKind.VISUAL_FOCUS_SNAPSHOT,
                    sequence = focus.stateVersion,
                    sessionId = sessionID,
                    senderId = guideID,
                    payload = focus.encode(),
                ),
            ),
        )
    }
}

private fun presentationCredential(sessionID: UUID): SessionCredential =
    SessionCredential.derive("23456789AB", sessionID)
