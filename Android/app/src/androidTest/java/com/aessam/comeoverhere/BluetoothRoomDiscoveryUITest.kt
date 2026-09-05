package com.aessam.comeoverhere

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.aessam.comeoverhere.core.Channel
import com.aessam.comeoverhere.ui.ChannelListView
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class BluetoothRoomDiscoveryUITest {
    @get:Rule val compose = createComposeRule()
    @Test fun discoveryOnlyRoomIsVisibleButCannotJoinUntilLANResolves() {
        val room = mutableStateOf(Channel("room", "Nearby room", 0.0, "remote", roomAdmissionVersion = 1, isRoomLocked = false))
        var joined = false
        compose.setContent { MaterialTheme { ChannelListView(listOf(room.value), "local") { joined = true } } }
        compose.onNodeWithText("Nearby room").assertIsDisplayed()
        compose.onNodeWithText("Nearby via Bluetooth · Audio unavailable").assertIsDisplayed()
        compose.onNodeWithText("Nearby room").performClick()
        compose.runOnIdle { assertFalse(joined); room.value = room.value.copy(audioHostIP = "192.0.2.1") }
        compose.onNodeWithText("Open room").assertIsDisplayed()
        compose.onNodeWithText("Nearby room").performClick()
        compose.runOnIdle { assertTrue(joined) }
    }
}
