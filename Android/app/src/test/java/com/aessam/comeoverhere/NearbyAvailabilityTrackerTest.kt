package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyAvailabilityTracker
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NearbyAvailabilityTrackerTest {
    @Test fun onlyRealAvailabilityTransitionsRestartRadioOwnership() {
        val tracker = NearbyAvailabilityTracker()
        tracker.seed(true)
        repeat(100) { assertFalse(tracker.changed(true)) }
        assertTrue(tracker.changed(false))
        repeat(100) { assertFalse(tracker.changed(false)) }
        assertTrue(tracker.changed(true))
        tracker.seed(true)
        assertFalse(tracker.changed(true))
    }
}
