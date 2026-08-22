package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.LocalTargetGuidance
import com.aessam.toursession.TargetSnapshotPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.util.UUID

class LocalGuidanceServiceTest {
    @Test
    fun guidanceUsesLocalPositionWithoutChangingSharedTarget() {
        val target = TargetSnapshotPayload(
            stateVersion = 1,
            targetID = UUID.randomUUID(),
            latitudeE7 = 377_749_000,
            longitudeE7 = -1_224_194_000,
            label = "Gate",
            isVisible = true,
        )

        val guidance = LocalTargetGuidance.calculate(
            latitude = 37.7740,
            longitude = -122.4194,
            headingDegrees = 90.0,
            target = target,
        )

        assertEquals(100.1, guidance.distanceMeters, 1.0)
        assertEquals(0.0, guidance.targetBearingDegrees, 1.0)
        assertNotNull(guidance.relativeArrowDegrees)
        assertEquals(270.0, guidance.relativeArrowDegrees!!, 1.0)
        assertEquals(377_749_000, target.latitudeE7)
        assertEquals(-1_224_194_000, target.longitudeE7)
    }
}
