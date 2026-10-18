package com.aessam.comeoverhere

import android.os.Bundle
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.material3.AlertDialog
import androidx.core.content.IntentCompat
import android.net.Uri
import android.content.Intent
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import org.maplibre.android.MapLibre
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.aessam.comeoverhere.ui.AppViewModel
import com.aessam.comeoverhere.ui.AppViewModelFactory
import com.aessam.comeoverhere.ui.ChannelScreen
import com.aessam.comeoverhere.ui.WiFiAwareLabScreen

class MainActivity : ComponentActivity() {
    override fun onStart() {
        super.onStart()
        (application as ComeOverHereApp).channelService.setDiscoveryForeground(true)
    }
    override fun onStop() {
        (application as ComeOverHereApp).channelService.setDiscoveryForeground(false)
        super.onStop()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        importSharedTourPack(intent)
    }

    /** A `.gohtour` opened from Files/Mail (VIEW) or shared to the app (SEND), ADR-080. */
    private fun importSharedTourPack(intent: Intent?) {
        val uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
            else -> null
        } ?: return
        (application as ComeOverHereApp).importTourPack(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MapLibre.getInstance(this)
        if (savedInstanceState == null) importSharedTourPack(intent)
        val channelService = (application as ComeOverHereApp).channelService

        setContent {
            MaterialTheme {
                val vm: AppViewModel = viewModel(factory = AppViewModelFactory(channelService))
                var showWiFiAwareLab by remember { mutableStateOf(false) }
                var showGateway by remember { mutableStateOf(false) }
                var showPreparedTours by remember { mutableStateOf(false) }
                val gateway = (application as ComeOverHereApp).gateway
                val gatewayState by gateway.status.collectAsState()
                val app = application as ComeOverHereApp
                val packMessage by app.packImportMessage.collectAsState()
                packMessage?.let { message ->
                    AlertDialog(
                        onDismissRequest = { app.packImportMessage.value = null },
                        confirmButton = { TextButton(onClick = { app.packImportMessage.value = null }) { Text("OK") } },
                        text = { Text(message) },
                    )
                }
                if (showPreparedTours) {
                    com.aessam.comeoverhere.ui.PreparedToursScreen(app.preparedTours, channelService, onBack = { showPreparedTours = false })
                } else if (showGateway || gatewayState.role == com.aessam.comeoverhere.service.GatewayRole.COMPANION) {
                    com.aessam.comeoverhere.ui.GatewayScreen(gateway, onBack = { showGateway = false })
                } else if (showWiFiAwareLab && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    WiFiAwareLabScreen(onBack = { showWiFiAwareLab = false })
                } else {
                    ChannelScreen(vm, onOpenWiFiAwareLab = { showWiFiAwareLab = true }, onOpenGateway = { showGateway = true },
                        onOpenPreparedTours = { showPreparedTours = true })
                }
            }
        }
    }
}
