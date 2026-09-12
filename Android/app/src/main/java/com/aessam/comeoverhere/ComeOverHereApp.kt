package com.aessam.comeoverhere

import android.app.Application
import android.os.Build
import android.util.Log
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.NetworkCoordinator
import com.aessam.comeoverhere.service.AudioEngine
import com.aessam.comeoverhere.service.ChannelService
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.ListenState
import com.aessam.comeoverhere.service.LocalGuidanceService
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.comeoverhere.service.TourAudioForegroundService
import com.aessam.comeoverhere.service.TourContentStore
import com.aessam.comeoverhere.service.TourControlService
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class ComeOverHereApp : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var coordinator: NetworkCoordinator
    internal lateinit var audioEngine: AudioEngine
        private set
    lateinit var channelService: ChannelService
        private set
    lateinit var gateway: com.aessam.comeoverhere.service.GatewaySessionCoordinator
        private set

    override fun onCreate() {
        super.onCreate()
        coordinator = NetworkCoordinator(this, Build.MODEL, applicationScope)
        audioEngine = AudioEngine(this)
        channelService = ChannelService(
            coordinator,
            audioEngine,
            applicationScope,
            TourControlService(),
            TourAssetTransferService(
                LocalSessionAssetTransport(),
                FileTourAssetCache(File(filesDir, "asset-cache")),
            ),
            TourContentStore(File(filesDir, "tour-packs")),
            LocalGuidanceService(this),
        )
        coordinator.start()
        channelService.start()
        gateway = com.aessam.comeoverhere.service.GatewaySessionCoordinator(this, channelService, applicationScope)
        applicationScope.launch {
            combine(channelService.listenState, gateway.status) { audio, gateway -> audio to gateway }.collectLatest { (state, gatewayState) ->
                when (state) {
                    ListenState.BROADCASTING -> TourAudioForegroundService.startGuide(this@ComeOverHereApp,
                        gatewayState.role == com.aessam.comeoverhere.service.GatewayRole.GUIDE)
                    ListenState.LISTENING -> TourAudioForegroundService.startGuest(this@ComeOverHereApp)
                    ListenState.IDLE -> if (gatewayState.role == com.aessam.comeoverhere.service.GatewayRole.COMPANION)
                        TourAudioForegroundService.startCompanion(this@ComeOverHereApp)
                        else TourAudioForegroundService.stop(this@ComeOverHereApp)
                }
            }
        }
        Log.i(TAG, "Application tour services started")
    }

    companion object {
        private const val TAG = "ComeOverHereApp"
    }
}
