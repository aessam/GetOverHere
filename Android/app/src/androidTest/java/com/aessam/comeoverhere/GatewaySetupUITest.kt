package com.aessam.comeoverhere

import android.Manifest
import android.view.WindowManager
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.service.GatewayRole
import com.aessam.comeoverhere.service.GatewayState
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual production navigation and interface inventory; no radio, pairing or audio claim. */
@RunWith(AndroidJUnit4::class)
class GatewaySetupUITest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test(timeout = 30_000)
    fun idleCompanionSetupShowsActualStateAndReturnsWithoutChangingPermissions() {
        val app = compose.activity.application as ComeOverHereApp
        val permissionNames = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO,
            Manifest.permission.NEARBY_WIFI_DEVICES, Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        val before = compose.runOnIdle {
            assertNull("Do not replace an existing tour", app.channelService.activeChannelID.value)
            assertEquals(GatewayRole.NONE, app.gateway.status.value.role)
            assertEquals(GatewayState.IDLE, app.gateway.status.value.state)
            val keepAwake = compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            keepAwake to permissionNames.associateWith(app::checkSelfPermission)
        }
        try {
            compose.onNodeWithText("Companion").assertIsDisplayed().performClick()
            compose.onNodeWithText("Wired companion").assertIsDisplayed()
            compose.onNodeWithTag("gatewayStatus").assertIsDisplayed().assertTextEquals("none · idle")
            compose.onNodeWithText("Refresh USB interfaces").performScrollTo().assertIsDisplayed()

            // Join the real read-only inventory operation so its asynchronous
            // result, including an actually empty inventory, drives assertions.
            val refresh = compose.runOnIdle { app.gateway.refreshInterfaces() }
            runBlocking { withTimeout(5_000) { refresh.join() } }
            compose.waitForIdle()
            val interfaces = compose.runOnIdle { app.gateway.addresses.value.toList() }
            if (interfaces.isEmpty()) {
                compose.onNodeWithText("No wired interface detected. Check the cable, USB role, and tethering setting.")
                    .performScrollTo().assertIsDisplayed()
            } else {
                interfaces.forEach { candidate ->
                    compose.onNodeWithText(candidate.displayName).performScrollTo().assertIsDisplayed()
                }
            }
            for (tag in listOf("gatewayCreateOffer", "gatewayScanOffer")) {
                val action = compose.onNodeWithTag(tag).performScrollTo().assertIsDisplayed()
                if (interfaces.size == 1) action.assertIsEnabled() else action.assertIsNotEnabled()
            }
            // Do not tap pairing/scanning actions: they require real hardware
            // and user permission. This smoke only proves their actual UI state.
            compose.onNodeWithText("Back to tour").performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithTag("gatewayStatus").assertDoesNotExist()
            compose.onNodeWithText("Companion").assertIsDisplayed()
            compose.onNodeWithContentDescription("Create Channel").assertIsDisplayed()
            compose.onNodeWithTag("findNearbyTours").assertIsDisplayed()
            compose.runOnIdle {
                assertNull(app.channelService.activeChannelID.value)
                assertEquals(GatewayRole.NONE, app.gateway.status.value.role)
                assertEquals(before.first,
                    compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                assertEquals(before.second, permissionNames.associateWith(app::checkSelfPermission))
            }
        } finally {
            compose.runOnIdle {
                compose.activity.window.setFlags(before.first, WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }
}
