package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.DirectGuestAdmission
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ADR-081 T5 (QST-1): with a bridge assigned, other-platform guests connect directly only as bridge or standby. */
class DirectGuestAdmissionTest {
    private val bridge = UUID.randomUUID()
    private val standby = UUID.randomUUID()

    private fun assignment(standbys: List<UUID>) =
        BridgeAssignmentPayload(1, bridge, ParticipantPlatform.IOS, Long.MAX_VALUE, standbys)

    @Test fun everyoneIsAdmittedWithoutABridge() {
        assertTrue(DirectGuestAdmission(ParticipantPlatform.ANDROID).admits(UUID.randomUUID(), ParticipantPlatform.IOS, false))
    }

    @Test fun bridgeAndTwoStandbysOnlyThenRefuse() {
        val policy = DirectGuestAdmission(ParticipantPlatform.ANDROID)
        policy.update(assignment(listOf(standby)))
        assertTrue(policy.admits(bridge, ParticipantPlatform.IOS, true))
        assertTrue(policy.admits(standby, ParticipantPlatform.IOS, true))
        assertFalse("non-relay guests use the island", policy.admits(UUID.randomUUID(), ParticipantPlatform.IOS, false))
        val second = UUID.randomUUID()
        assertTrue("a free standby slot", policy.admits(second, ParticipantPlatform.IOS, true))
        policy.update(assignment(listOf(standby, second)))
        assertFalse("standbys are full", policy.admits(UUID.randomUUID(), ParticipantPlatform.IOS, true))
        assertTrue("same-platform guests are unaffected", policy.admits(UUID.randomUUID(), ParticipantPlatform.ANDROID, false))
    }

    @Test fun guestsAdmittedEarlierAreReadmitted() {
        val policy = DirectGuestAdmission(ParticipantPlatform.ANDROID)
        val early = UUID.randomUUID()
        assertTrue(policy.admits(early, ParticipantPlatform.IOS, false))
        policy.update(assignment(listOf(standby, UUID.randomUUID())))
        assertTrue("a reconnect is never stranded", policy.admits(early, ParticipantPlatform.IOS, false))
    }

    @Test fun refusedGuestNeverGetsAWelcome() {
        val port = ServerSocket(0).use { it.localPort }
        val guide = LocalSessionControlTransport(port)
        val guest = LocalSessionControlTransport(port)
        val session = UUID.randomUUID()
        val credential = SessionCredential.derive("23456789AB", session)
        val guideEvents = CopyOnWriteArrayList<SessionControlEvent>()
        val guestEvents = CopyOnWriteArrayList<SessionControlEvent>()
        try {
            val policy = DirectGuestAdmission(ParticipantPlatform.ANDROID)
            policy.update(assignment(listOf(standby, UUID.randomUUID())))
            guide.setDirectGuestAdmission(policy)
            guide.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guide.configureSession(session, UUID.randomUUID(), "Guide", ParticipantPlatform.ANDROID, credential)
            guide.setEventHandler { guideEvents += it }
            guide.startGuide()
            guest.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guest.configureSession(session, UUID.randomUUID(), "iPhone", ParticipantPlatform.IOS, credential)
            guest.hostIP = "127.0.0.1"
            guest.setEventHandler { guestEvents += it }
            guest.startGuest()
            val deadline = System.currentTimeMillis() + 5_000
            while (guestEvents.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
            assertTrue("the refused guest sees its lane end", guestEvents.isNotEmpty())
            assertFalse(guestEvents.any { it == SessionControlEvent.Connected })
            assertFalse(guideEvents.any { it is SessionControlEvent.GuestJoined })
        } finally {
            guest.stop(); guide.stop()
        }
    }
}
