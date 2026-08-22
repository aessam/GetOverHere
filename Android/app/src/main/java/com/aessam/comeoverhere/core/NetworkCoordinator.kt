package com.aessam.comeoverhere.core

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import com.aessam.toursession.AwareSessionAnnouncement
import com.aessam.toursession.SessionTransportRoute
import java.util.UUID

/**
 * Serverless local-LAN coordinator.
 * Discovery uses Android NSD; audio uses direct TCP between peers on the same Wi-Fi network.
 */
class NetworkCoordinator(
    context: Context,
    displayName: String,
    private val scope: CoroutineScope
) {
    val controlPlane = LocalControlPlane(context, displayName)
    val udpAudio = UDPAudioPlane()
    val wiFiAware = WiFiAwareSessionTransport(context)
    val awareAnnouncements = wiFiAware.announcements
    val awareSnapshot = wiFiAware.snapshot

    var activeAudioPlane: AudioPlane? = null; private set

    val hasIosPeers: Boolean
        get() = controlPlane.connectedPeers.value.any { it.platform == PeerInfo.Platform.IOS }

    private var commandJob: Job? = null
    private var peerJob: Job? = null

    companion object {
        private const val TAG = "NetworkCoordinator"
    }

    fun start() {
        controlPlane.start()
        wiFiAware.start()
        listenForCommands()
        listenForPeerChanges()
        Log.i(TAG, "NetworkCoordinator started")
    }

    fun stop() {
        controlPlane.stop()
        wiFiAware.close()
        activeAudioPlane?.stop()
        activeAudioPlane = null
        commandJob?.cancel()
        peerJob?.cancel()
    }

    fun selectAudioPlane(
        route: SessionTransportRoute = SessionTransportRoute.LOCAL_LAN,
        awareRoute: WiFiAwareSessionTransport.GuestRoute? = null,
    ): AudioPlane {
        udpAudio.setGuestSocketFactory(
            if (route == SessionTransportRoute.WIFI_AWARE) awareRoute?.network?.socketFactory else null,
        )
        Log.i(TAG, "Audio plane selected: ${route.name.lowercase()}")
        activeAudioPlane = udpAudio
        return udpAudio
    }

    fun enableWiFiAware() {
        wiFiAware.start()
    }

    fun hostWiFiAware(announcement: AwareSessionAnnouncement) {
        wiFiAware.host(announcement)
    }

    fun stopWiFiAwareHosting() {
        wiFiAware.stopHosting()
    }

    fun connectWiFiAware(
        sessionID: UUID,
        completion: (Result<WiFiAwareSessionTransport.GuestRoute>) -> Unit,
    ) {
        wiFiAware.connect(sessionID, completion)
    }

    private fun listenForCommands() {
        commandJob = scope.launch {
            controlPlane.commands.collect { (command, peer) ->
                Log.d(TAG, "${command.javaClass.simpleName} observed from ${peer.platform.rawValue} peer")
            }
        }
    }

    private fun listenForPeerChanges() {
        peerJob = scope.launch {
            controlPlane.peerEvents.collect { event ->
                if (event is PeerEvent.Connected) {
                    Log.i(TAG, "${event.peer.platform.rawValue} peer connected")
                }
            }
        }
    }
}
