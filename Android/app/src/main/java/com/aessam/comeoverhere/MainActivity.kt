package com.aessam.comeoverhere

import android.os.Bundle
import android.os.Build
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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
