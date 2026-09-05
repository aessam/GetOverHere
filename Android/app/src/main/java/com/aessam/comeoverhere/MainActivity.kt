package com.aessam.comeoverhere

import android.os.Bundle
import android.os.Build
import android.content.pm.PackageManager
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import org.maplibre.android.MapLibre
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.aessam.comeoverhere.ui.AppViewModel
import com.aessam.comeoverhere.ui.AppViewModelFactory
import com.aessam.comeoverhere.ui.ChannelScreen
import com.aessam.comeoverhere.ui.WiFiAwareLabScreen

class MainActivity : ComponentActivity() {
    private val bluetoothPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.any { !it }) Log.w("MainActivity", "Bluetooth room discovery permission denied")
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val required = BluetoothRoomDiscovery.requiredPermissions()
        if (savedInstanceState == null && required.any { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }) {
            bluetoothPermissions.launch(required)
        }
        MapLibre.getInstance(this)
        val channelService = (application as ComeOverHereApp).channelService

        setContent {
            MaterialTheme {
                val vm: AppViewModel = viewModel(factory = AppViewModelFactory(channelService))
                var showWiFiAwareLab by remember { mutableStateOf(false) }
                if (showWiFiAwareLab && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    WiFiAwareLabScreen(onBack = { showWiFiAwareLab = false })
                } else {
                    ChannelScreen(vm, onOpenWiFiAwareLab = { showWiFiAwareLab = true })
                }
            }
        }
    }
}
