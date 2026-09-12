package com.aessam.comeoverhere.core

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Serverless local-LAN coordinator.
 * Discovery uses NSD and Bluetooth; audio still uses direct TCP over a shared LAN.
 */
class NetworkCoordinator(
    val controlPlane: ControlPlane,
    private val udpAudio: AudioPlane,
    private val scope: CoroutineScope,
) {
    /** Production constructor: NSD discovery plus the local TCP realtime lane. */
    constructor(context: Context, displayName: String, scope: CoroutineScope) : this(
        LocalControlPlane(context, displayName),
        UDPAudioPlane(),
        scope,
    )

    var activeAudioPlane: AudioPlane? = null; private set
    fun captureDiagnostics(): Map<String, Any> = (activeAudioPlane as? UDPAudioPlane)?.captureDiagnostics() ?: emptyMap()

    val hasIosPeers: Boolean
        get() = controlPlane.connectedPeers.value.any { it.platform == PeerInfo.Platform.IOS }

    private var commandJob: Job? = null
    private var peerJob: Job? = null

    companion object {
        private const val TAG = "NetworkCoordinator"
    }

    fun start() {
        controlPlane.start()
        listenForCommands()
        listenForPeerChanges()
        Log.i(TAG, "NetworkCoordinator started")
    }

    fun stop() {
        controlPlane.stop()
        activeAudioPlane?.stop()
        activeAudioPlane = null
        commandJob?.cancel()
        peerJob?.cancel()
    }

    fun selectAudioPlane(): AudioPlane {
        udpAudio.setGuestSocketFactory(null)
        Log.i(TAG, "Audio plane selected: local LAN")
        activeAudioPlane = udpAudio
        return udpAudio
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
