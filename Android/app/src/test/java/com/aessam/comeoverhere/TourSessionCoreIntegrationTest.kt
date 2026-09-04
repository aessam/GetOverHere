package com.aessam.comeoverhere

import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.TourSessionFixtures
import org.junit.Assert.assertEquals
import org.junit.Test

class TourSessionCoreIntegrationTest {
    @Test
    fun androidAppConsumesSharedGoh2Contract() {
        val fixture = TourSessionFixtures.helloEnvelope()
        assertEquals(2, SessionEnvelope.MAJOR_VERSION)
        assertEquals(4, SealedSessionEnvelope.MAJOR_VERSION)
        assertEquals(fixture, SessionEnvelope.decode(fixture.encode()))
    }
}
