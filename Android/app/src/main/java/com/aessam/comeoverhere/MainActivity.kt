package com.aessam.comeoverhere

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.aessam.comeoverhere.core.NetworkCoordinator
import com.aessam.comeoverhere.service.AudioEngine
import com.aessam.comeoverhere.service.ChannelService
import com.aessam.comeoverhere.ui.AppViewModel
import com.aessam.comeoverhere.ui.AppViewModelFactory
import com.aessam.comeoverhere.ui.ChannelScreen
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class MainActivity : ComponentActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var coordinator: NetworkCoordinator
    private lateinit var channelService: ChannelService
    private lateinit var audioEngine: AudioEngine

    private val requiredPermissions: Array<String>
        get() = arrayOf(Manifest.permission.RECORD_AUDIO)

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        if (!results.values.all { it }) {
            Log.w(TAG, "Some permissions denied: ${results.filter { !it.value }.keys}")
        }
        startServices()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val deviceName = Build.MODEL
        coordinator = NetworkCoordinator(this, deviceName, scope)
        audioEngine = AudioEngine()
        channelService = ChannelService(coordinator, audioEngine, scope)

        setContent {
            MaterialTheme {
                val vm: AppViewModel = viewModel(factory = AppViewModelFactory(channelService))
                ChannelScreen(vm)
            }
        }

        requestPermissionsIfNeeded()
    }

    override fun onDestroy() {
        super.onDestroy()
        channelService.stop()
        coordinator.stop()
    }

    private fun requestPermissionsIfNeeded() {
        val missing = requiredPermissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startServices()
        else permissionLauncher.launch(missing.toTypedArray())
    }

    private fun startServices() {
        coordinator.start()
        channelService.start()
        Log.i(TAG, "All services started")
    }

    companion object {
        private const val TAG = "MainActivity"
    }
}
