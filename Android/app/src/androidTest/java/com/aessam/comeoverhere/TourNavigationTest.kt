package com.aessam.comeoverhere

import android.Manifest
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.rule.GrantPermissionRule
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import com.aessam.toursession.TourVisualMode

class TourNavigationTest {
    @get:Rule(order = 0)
    val tourPermissions: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )

    @get:Rule(order = 1)
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun guideCanReachSlidesMapAndPointerWithoutLegacyConfiguration() {
        composeRule.onNodeWithContentDescription("Create Channel").performClick()
        composeRule.onNodeWithText("Channel name").performTextInput("Alhambra")
        composeRule.onNodeWithText("Create").performClick()

        composeRule.onNodeWithText("Slides").assertIsDisplayed()
        composeRule.onNodeWithText("Map").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("No offline map").assertIsDisplayed()
        composeRule.onNodeWithText("Import Offline Map").assertIsDisplayed()
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
        ).assertIsDisplayed()
        assertTrue(composeRule.onAllNodesWithText("Audio Quality").fetchSemanticsNodes().isEmpty())

        composeRule.onNodeWithText("End Tour").performClick()
        composeRule.onNodeWithText("No megaphones nearby").assertIsDisplayed()
    }

    private fun channelService() =
        (composeRule.activity.application as ComeOverHereApp).channelService
}
