package com.aessam.comeoverhere.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.Channel
import com.aessam.comeoverhere.core.PeerInfo
import com.aessam.comeoverhere.service.ChannelServiceProtocol
import kotlinx.coroutines.flow.*

class AppViewModel(
    private val channelService: ChannelServiceProtocol
) : ViewModel() {

    val channels = channelService.channels
    val activeChannelID = channelService.activeChannelID
    val listenState = channelService.listenState
    val listenerCount = channelService.listenerCount
    val connectedPeers = channelService.connectedPeers
    val localPeerID = channelService.localPeerID

    val activeChannel: StateFlow<Channel?> = combine(channels, activeChannelID) { chList, id ->
        chList.find { it.id == id }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun createChannel(name: String, quality: AudioQuality = AudioQuality.STANDARD) {
        val trimmed = name.trim()
        if (trimmed.isBlank() || trimmed.length > 32) return
        channelService.createChannel(trimmed, quality)
    }

    fun joinChannel(channel: Channel) = channelService.joinChannel(channel)
    fun leaveChannel() = channelService.leaveChannel()
}

class AppViewModelFactory(
    private val channelService: ChannelServiceProtocol
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = AppViewModel(channelService) as T
}
