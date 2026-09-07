package com.aessam.comeoverhere.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.aessam.comeoverhere.core.Channel
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.core.PeerInfo
import com.aessam.comeoverhere.service.ChannelServiceProtocol
import com.aessam.comeoverhere.service.SlideImport
import com.aessam.comeoverhere.service.OfflineMapImport
import kotlinx.coroutines.flow.*

class AppViewModel(
    private val channelService: ChannelServiceProtocol
) : ViewModel() {

    val channels = channelService.channels
    val awareSettings = channelService.awareSettings
    fun canJoin(channel: Channel) = channelService.canJoin(channel)
    val bluetoothDiscoveryEnabled = channelService.bluetoothDiscoveryEnabled
    fun setBluetoothDiscoveryEnabled(enabled: Boolean) = channelService.setBluetoothDiscoveryEnabled(enabled)
    val activeChannelID = channelService.activeChannelID
    val listenState = channelService.listenState
    val listenerCount = channelService.listenerCount
    val connectedGuestCount = channelService.connectedGuestCount
    val speakerFeedbackWarning = channelService.speakerFeedbackWarning
    val readyParticipantCount = channelService.readyParticipantCount
    val listenerOutput = channelService.listenerOutput
    val presentationSnapshot = channelService.presentationSnapshot
    val slides = channelService.slides
    val readySlideFiles = channelService.readySlideFiles
    val isImportingSlides = channelService.isImportingSlides
    val isImportingMap = channelService.isImportingMap
    val offlineMapConfiguration = channelService.offlineMapConfiguration
    val offlineMapStatus = channelService.offlineMapStatus
    val tourFeatureError = channelService.tourFeatureError
    val tourCode = channelService.tourCode
    val isRoomLocked = channelService.isRoomLocked
    val isUpdatingRoomAccess = channelService.isUpdatingRoomAccess
    val roomAccessError = channelService.roomAccessError
    fun updateRoomAccess(locked: Boolean, code: String) = channelService.updateRoomAccess(locked, code)
    val connectionState = channelService.connectionState
    val reconnectAttempt = channelService.reconnectAttempt
    val targetSnapshot = channelService.targetSnapshot
    val bearingSnapshot = channelService.bearingSnapshot
    val visualFocusSnapshot = channelService.visualFocusSnapshot
    val localGuidanceService = channelService.localGuidanceService
    val localPeerID = channelService.localPeerID

    val activeChannel: StateFlow<Channel?> = combine(channels, activeChannelID) { chList, id ->
        chList.find { it.id == id }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun createChannel(name: String) {
        val trimmed = name.trim()
        if (trimmed.isBlank() || trimmed.length > 32) return
        channelService.createChannel(trimmed)
    }

    fun joinChannel(channel: Channel, tourCode: String) = channelService.joinChannel(channel, tourCode)
    fun setListenerOutput(output: ListenerOutput) = channelService.setListenerOutput(output)
    fun leaveChannel() = channelService.leaveChannel()
    fun importSlides(imports: List<SlideImport>) = channelService.importSlides(imports)
    fun moveSlide(assetID: String, destinationIndex: Int) =
        channelService.moveSlide(assetID, destinationIndex)
    fun removeSlide(assetID: String) = channelService.removeSlide(assetID)
    fun importOfflineMap(import: OfflineMapImport) = channelService.importOfflineMap(import)
    fun showSlide(assetID: String? = null) = channelService.showSlide(assetID)
    fun hideSlides() = channelService.hideSlides()
    fun previousSlide() = channelService.previousSlide()
    fun nextSlide() = channelService.nextSlide()
    fun setVisualFocus(mode: com.aessam.toursession.TourVisualMode) = channelService.setVisualFocus(mode)
    fun setTarget(latitude: Double, longitude: Double, label: String = "") =
        channelService.setTarget(latitude, longitude, label)
    fun clearTarget() = channelService.clearTarget()
    fun shareCurrentBearing() = channelService.shareCurrentBearing()
    fun clearBearing() = channelService.clearBearing()
}

class AppViewModelFactory(
    private val channelService: ChannelServiceProtocol
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = AppViewModel(channelService) as T
}
