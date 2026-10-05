package com.aessam.comeoverhere

import android.Manifest
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.assertIsOff
import androidx.test.rule.GrantPermissionRule
import org.junit.Rule
import org.junit.Test
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import com.aessam.toursession.TourVisualMode
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import com.aessam.comeoverhere.service.SessionConnectionState
import java.net.ServerSocket

class TourNavigationTest {
    @After fun releaseTourEvenWhenAnAssertionFails() {
        // The application intentionally outlives Activity recreation. Tests must end their tour.
        composeRule.runOnIdle {
            channelService().leaveChannel()
            channelService().stop()
            channelService().setBluetoothDiscoveryEnabled(false)
            channelService().awareSettings?.setEnabled(false)
        }
    }
    @Test fun bluetoothDiscoveryDefaultsOffAndRequiresExplicitIntent() {
        composeRule.runOnIdle { channelService().setBluetoothDiscoveryEnabled(false) }
        composeRule.onNodeWithTag("findNearbyTours").assertIsDisplayed().performClick()
        composeRule.waitUntil(2_000) { channelService().bluetoothDiscoveryEnabled.value }
        composeRule.onNodeWithContentDescription("Connection diagnostics").performClick()
        composeRule.onNodeWithTag("bluetoothRoomDiscovery").performClick()
        composeRule.waitUntil(2_000) { !channelService().bluetoothDiscoveryEnabled.value }
    }
    @get:Rule(order = 0)
    val tourPermissions: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.NEARBY_WIFI_DEVICES,
            *BluetoothRoomDiscovery.requiredPermissions(),
        )

    @get:Rule(order = 1)
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun failedStartupShowsReasonOnChannelList() {
        // Force the production control listener to fail before publishing a tour.
        ServerSocket(50_001).use {
            composeRule.onNodeWithContentDescription("Create Channel").performClick()
            composeRule.onNodeWithText("Channel name").performTextInput("Startup failure")
            composeRule.onNodeWithText("Create").performClick()
            composeRule.waitUntil(10_000) {
                channelService().connectionState.value == SessionConnectionState.FAILED
            }
            composeRule.onNodeWithText("Could not start tour").assertIsDisplayed()
            val reason = requireNotNull(channelService().tourFeatureError.value)
            assertTrue(reason.contains("bind/listen failed"))
            composeRule.onNodeWithText(reason).assertIsDisplayed()
            composeRule.onNodeWithContentDescription("Create Channel").assertIsDisplayed()
            assertEquals(null, channelService().activeChannelID.value)
        }
    }

    @Test
    fun guideCanReachSlidesMapAndPointerWithoutLegacyConfiguration() {
        composeRule.onNodeWithContentDescription("Create Channel").performClick()
        composeRule.onNodeWithText("Channel name").performTextInput("Alhambra")
        composeRule.onNodeWithText("Create").performClick()

        // Credential stretching is asynchronous; Compose idleness alone does not mean startup finished.
        composeRule.waitUntil(10_000) {
            channelService().connectionState.value == SessionConnectionState.CONNECTED
        }

        assertEquals(false, channelService().isRoomLocked.value)
        composeRule.onNodeWithText("Room code (4–64 characters)").performTextInput("1234")
        composeRule.onNodeWithTag("roomLockToggle").performClick()
        composeRule.waitUntil(10_000) { channelService().isRoomLocked.value }
        assertEquals("1234", channelService().tourCode.value)
        composeRule.onNodeWithText("Room code (4–64 characters)").performTextReplacement("Edited!")
        composeRule.onNodeWithText("Save Code").performClick()
        composeRule.waitUntil(10_000) { channelService().tourCode.value == "Edited!" }
        composeRule.onNodeWithTag("roomLockToggle").performClick()
        composeRule.waitUntil(10_000) { !channelService().isRoomLocked.value }

        composeRule.onNodeWithText("Slides").assertIsDisplayed()
        composeRule.onNodeWithTag("importPDF").assertExists().assertIsEnabled()
        composeRule.onNodeWithText("Map").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("No offline map").assertIsDisplayed()
        composeRule.onNodeWithText("Import Offline Map").performScrollTo().assertIsDisplayed()
        composeRule.waitUntil(2_000) {
            channelService().visualFocusSnapshot.value?.mode == TourVisualMode.MAP
        }
        assertEquals(TourVisualMode.MAP, channelService().visualFocusSnapshot.value?.mode)
        composeRule.onNodeWithText("Pointer").assertIsDisplayed().performClick()
        composeRule.waitUntil(2_000) {
            channelService().visualFocusSnapshot.value?.mode == TourVisualMode.POINTER
        }
        assertEquals(TourVisualMode.POINTER, channelService().visualFocusSnapshot.value?.mode)
        composeRule.onNodeWithText(
            "Only the selected bearing angle is shared. Device location and guest compass readings stay local.",
        ).performScrollTo().assertIsDisplayed()
        assertTrue(composeRule.onAllNodesWithText("Audio Quality").fetchSemanticsNodes().isEmpty())

        composeRule.onNodeWithText("End Tour").performClick()
        composeRule.waitUntil(5_000) { channelService().activeChannelID.value == null }
        composeRule.onNodeWithContentDescription("Create Channel").assertIsDisplayed()
    }

    private fun channelService() =
        (composeRule.activity.application as ComeOverHereApp).channelService
}
