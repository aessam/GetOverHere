package com.aessam.comeoverhere.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.aessam.comeoverhere.core.NearbyAwareSettings
import com.aessam.comeoverhere.core.NearbyAwareProfile

@Composable
fun NearbyAwareSettingsView(settings: NearbyAwareSettings, showAdvancedControls: Boolean = true) {
    val state by settings.state.collectAsState()
    val context = LocalContext.current
    var pin by remember { mutableStateOf("") }
    var permissionError by remember { mutableStateOf<String?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionError = if (granted) null else "Nearby Wi-Fi permission denied. Enable it in Settings to try again."
        settings.setEnabled(granted)
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        if (showAdvancedControls) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Wi-Fi Aware (experimental)", modifier = Modifier.weight(1f))
            Switch(state.enabled, onCheckedChange = { enabled ->
                permissionError = null
                if (!enabled || ContextCompat.checkSelfPermission(context, Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED) {
                    settings.setEnabled(enabled)
                } else permission.launch(Manifest.permission.NEARBY_WIFI_DEVICES)
            }, modifier = Modifier.testTag("awareRoomDiscovery"))
        }
        }
        if (state.enabled) {
            Text("Experimental nearby Wi-Fi link. Keep Wi-Fi enabled; no router or Internet is needed. Device pairing is separate from the optional room code. Mixed-platform pairing still needs physical qualification.",
                style = MaterialTheme.typography.bodySmall)
            if (state.hosting) {
                if (NearbyAwareProfile.ANDROID_PSK in state.profiles) {
                    Text("Android compatibility PIN: ${state.pin}")
                    Text("Enter this PIN for Android compatibility connections. Your room stays open unless you lock it.", style = MaterialTheme.typography.bodySmall)
                }
                if (NearbyAwareProfile.SYSTEM_PAIRED in state.profiles) {
                    Text("System pairing is available. Complete any pairing confirmation shown by Android.", style = MaterialTheme.typography.bodySmall)
                }
            } else {
                if (state.peers.any { it.requiresPIN }) {
                    OutlinedTextField(pin, onValueChange = { pin = it.filter(Char::isDigit).take(8) },
                        label = { Text("Android compatibility PIN shown by guide") }, singleLine = true,
                        modifier = Modifier.testTag("awareCompatibilityPIN"))
                }
                LazyColumn(Modifier.heightIn(max = 160.dp)) {
                    items(state.peers, key = { it.id }) { peer ->
                        Button(onClick = { settings.pair(peer.id, if (peer.requiresPIN) pin else "") },
                            enabled = !peer.requiresPIN || pin.length in 4..8,
                            modifier = Modifier.testTag("awareConnect-${peer.id}")) {
                            Text("${if (peer.requiresPIN) "Pair" else "Connect"} ${peer.name}")
                        }
                    }
                }
                if (state.peers.isEmpty()) Text("Looking for nearby guides…", style = MaterialTheme.typography.bodySmall)
            }
            state.systemPairingUnavailableReason?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        (permissionError ?: state.error)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
