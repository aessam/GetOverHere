package com.aessam.comeoverhere

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TourRuntimeLifecycleTest {
    @Test
    fun activityRecreationRetainsApplicationTourRuntime() {
        var firstActivity: MainActivity? = null
        var firstService: Any? = null

        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                firstActivity = activity
                firstService = (activity.application as ComeOverHereApp).channelService
            }

            scenario.recreate()

            scenario.onActivity { activity ->
                assertNotSame(firstActivity, activity)
                assertSame(firstService, (activity.application as ComeOverHereApp).channelService)
            }
        }
    }
}
