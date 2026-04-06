package com.aessam.comeoverhere.service

import android.util.Log
import com.aessam.comeoverhere.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

/**
 * Audio-only megaphone service — matches iOS ChannelService architecture.
 * - Creator of a channel is the ONLY speaker
 * - Everyone else listens
 * - BLE control plane handles discovery + coordination
 * - Audio flows via UDP over WiFi hotspot (cross-platform)
 */

enum class ListenState { IDLE, LISTENING, BROADCASTING }

interface ChannelServiceProtocol {
    val channels: StateFlow<List<Channel>>
    val activeChannelID: StateFlow<String?>
    val listenState: StateFlow<ListenState>
    val listenerCount: StateFlow<Int>
    val connectedPeers: StateFlow<List<PeerInfo>>
    val localPeerID: String
    val audioQuality: AudioQuality

    fun start()
    fun stop()
    fun createChannel(name: String, quality: AudioQuality = AudioQuality.STANDARD)
    fun joinChannel(channel: Channel)
    fun leaveChannel()
}

class ChannelService(
    private val coordinator: NetworkCoordinator,
    private val audioEngine: AudioEngine,
    private val scope: CoroutineScope
) : ChannelServiceProtocol {

    private val _channels = MutableStateFlow<List<Channel>>(emptyList())
    override val channels: StateFlow<List<Channel>> = _channels.asStateFlow()

    private val _activeChannelID = MutableStateFlow<String?>(null)
    override val activeChannelID: StateFlow<String?> = _activeChannelID.asStateFlow()

    private val _listenState = MutableStateFlow(ListenState.IDLE)
    override val listenState: StateFlow<ListenState> = _listenState.asStateFlow()

    private val _listenerCount = MutableStateFlow(0)
    override val listenerCount: StateFlow<Int> = _listenerCount.asStateFlow()

    override val connectedPeers: StateFlow<List<PeerInfo>> = coordinator.controlPlane.connectedPeers
    override val localPeerID: String get() = coordinator.controlPlane.localPeer.id
    override var audioQuality: AudioQuality = AudioQuality.STANDARD

    private var captureJob: Job? = null

    val activeChannel: Channel?
        get() = _channels.value.find { it.id == _activeChannelID.value }

    val isCreator: Boolean
        get() = activeChannel?.createdBy == coordinator.controlPlane.localPeer.id

    companion object {
        private const val TAG = "ChannelService"
    }

    // MARK: - Lifecycle

    override fun start() {
        listenForChannelCommands()
        listenForPeerEvents()
        startPeriodicBroadcast()
        Log.i(TAG, "ChannelService started")
    }

    override fun stop() {
        stopCurrentActivity()
    }

    // MARK: - Channel Management

    override fun createChannel(name: String, quality: AudioQuality) {
        audioQuality = quality
        val channel = Channel(
            id = UUID.randomUUID().toString(),
            name = name,
            createdAt = nowAsSwiftRef(),
            createdBy = coordinator.controlPlane.localPeer.id
        )
        _channels.value = _channels.value + channel
        _activeChannelID.value = channel.id
        _listenState.value = ListenState.BROADCASTING

        // Announce via BLE
        broadcastChannelAnnounce(channel)

        // Select audio plane and start broadcasting
        val plane = coordinator.selectAudioPlane()
        plane.startBroadcasting(channelID = channel.id, quality = audioQuality)

        // Start capturing + sending audio
        startCapturing(plane, channel.id)
        Log.i(TAG, "Created megaphone: $name (quality: ${audioQuality.label})")
    }

    override fun joinChannel(channel: Channel) {
        stopCurrentActivity()
        _activeChannelID.value = channel.id
        _listenState.value = ListenState.LISTENING

        val plane = coordinator.selectAudioPlane()
        // For TCP audio: set the speaker's IP before connecting
        if (plane is UDPAudioPlane) {
            plane.hostIP = channel.audioHostIP
            Log.i(TAG, "TCP audio target: ${plane.hostIP}")
        }
        audioEngine.startPlayback()
        plane.startListening(channelID = channel.id) { data ->
            audioEngine.enqueuePlayback(data)
        }
        Log.i(TAG, "Listening to: ${channel.name}")
    }

    override fun leaveChannel() {
        val ch = activeChannel ?: return
        stopCurrentActivity()
        _activeChannelID.value = null
        _listenState.value = ListenState.IDLE
        Log.i(TAG, "Left channel: ${ch.name}")

        if (ch.createdBy == coordinator.controlPlane.localPeer.id) {
            _channels.value = _channels.value.filter { it.id != ch.id }
            coordinator.controlPlane.broadcast(BLECommand.ChannelEnded(channelID = ch.id))
        }
    }

    // MARK: - Private

    private fun startCapturing(plane: AudioPlane, channelID: String) {
        captureJob = scope.launch {
            audioEngine.startCapture().collect { pcmData ->
                if (!isActive) return@collect
                plane.sendAudio(pcmData)
            }
        }
    }

    private fun stopCurrentActivity() {
        if (_listenState.value == ListenState.BROADCASTING) {
            audioEngine.stopCapture()
            captureJob?.cancel()
            captureJob = null
        } else if (_listenState.value == ListenState.LISTENING) {
            audioEngine.stopPlayback()
        }
        coordinator.activeAudioPlane?.stop()
    }

    private fun broadcastChannelAnnounce(channel: Channel) {
        if (channel.createdBy != coordinator.controlPlane.localPeer.id) return
        val announce = BLECommand.ChannelAnnounce(
            channelID = channel.id,
            channelName = channel.name,
            createdBy = channel.createdBy,
            audioQuality = audioQuality,
            wifiSSID = null,
            audioHostIP = channel.audioHostIP
        )
        coordinator.controlPlane.broadcast(announce)
    }

    private fun broadcastAllChannels() {
        _channels.value.forEach { broadcastChannelAnnounce(it) }
    }

    // MARK: - Periodic Broadcast

    private fun startPeriodicBroadcast() {
        scope.launch {
            while (isActive) {
                delay(5000)
                if (_channels.value.isNotEmpty()) {
                    broadcastAllChannels()
                }
            }
        }
    }

    // MARK: - Command Listeners

    private fun listenForChannelCommands() {
        scope.launch {
            coordinator.controlPlane.commands.collect { (command, _) ->
                when (command) {
                    is BLECommand.ChannelAnnounce -> {
                        val existing = _channels.value.find { it.id == command.channelID }
                        if (existing != null) {
                            val updated = existing.copy(
                                name = command.channelName,
                                audioHostIP = command.audioHostIP
                            )
                            _channels.value = _channels.value.map {
                                if (it.id == command.channelID) updated else it
                            }
                            Log.i(TAG, "Updated megaphone: ${updated.name} (audioHostIP=${command.audioHostIP})")

                            if (_activeChannelID.value == updated.id &&
                                _listenState.value == ListenState.LISTENING &&
                                existing.audioHostIP != updated.audioHostIP) {
                                joinChannel(updated)
                            }
                        } else {
                            val channel = Channel(
                                id = command.channelID,
                                name = command.channelName,
                                createdAt = nowAsSwiftRef(),
                                createdBy = command.createdBy,
                                audioHostIP = command.audioHostIP
                            )
                            _channels.value = _channels.value + channel
                            Log.i(TAG, "Discovered megaphone: ${channel.name} (audioHostIP=${command.audioHostIP})")
                        }
                    }
                    is BLECommand.ChannelEnded -> {
                        _channels.value = _channels.value.filter { it.id != command.channelID }
                        if (_activeChannelID.value == command.channelID) {
                            stopCurrentActivity()
                            _activeChannelID.value = null
                            _listenState.value = ListenState.IDLE
                            Log.i(TAG, "Channel ended")
                        }
                    }
                    else -> { /* heartbeat, vote, wifi handled by coordinator */ }
                }
            }
        }
    }

    private fun listenForPeerEvents() {
        scope.launch {
            coordinator.controlPlane.peerEvents.collect { event ->
                when (event) {
                    is PeerEvent.Connected -> {
                        broadcastAllChannels()
                        _listenerCount.value = coordinator.controlPlane.connectedPeers.value.size
                    }
                    is PeerEvent.Disconnected -> {
                        _listenerCount.value = coordinator.controlPlane.connectedPeers.value.size
                    }
                    else -> {}
                }
            }
        }
    }
}
