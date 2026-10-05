package com.aessam.comeoverhere

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.aessam.comeoverhere.core.NearbyAwarePeer
import com.aessam.comeoverhere.core.NearbyAwareProfile
import com.aessam.comeoverhere.core.NearbyAwareSettings
import com.aessam.comeoverhere.core.NearbyAwareState
import com.aessam.comeoverhere.ui.NearbyAwareSettingsView
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** UI intent contract only; Android system pairing itself requires real capable devices. */
class NearbyAwareSettingsUITest {
    @get:Rule val compose = createComposeRule()

    @Test fun systemPairedPeerConnectsWithoutAnAppPINField() {
        val settings = SettingsDouble(NearbyAwareProfile.SYSTEM_PAIRED)
        compose.setContent { MaterialTheme { NearbyAwareSettingsView(settings) } }
        compose.onNodeWithTag("awareCompatibilityPIN").assertDoesNotExist()
        compose.onNodeWithText("Connect Guide").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals("peer" to "", settings.paired) }
    }

    @Test fun androidCompatibilityPeerStillRequiresTheExplicitGuidePIN() {
        val settings = SettingsDouble(NearbyAwareProfile.ANDROID_PSK)
        compose.setContent { MaterialTheme { NearbyAwareSettingsView(settings) } }
        compose.onNodeWithText("Pair Guide").assertIsNotEnabled()
        compose.onNodeWithTag("awareCompatibilityPIN").performTextInput("123456")
        compose.onNodeWithText("Pair Guide").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals("peer" to "123456", settings.paired) }
    }

    private class SettingsDouble(profile: NearbyAwareProfile) : NearbyAwareSettings {
        override val state = MutableStateFlow(NearbyAwareState(enabled = true,
            peers = listOf(NearbyAwarePeer("peer", "Guide", profile)), profiles = setOf(profile)))
        var paired: Pair<String, String>? = null
        override fun setEnabled(enabled: Boolean) { state.value = state.value.copy(enabled = enabled) }
        override fun pair(peerID: String, pin: String) { paired = peerID to pin }
    }
}
