package com.aessam.comeoverhere.service

import androidx.annotation.RequiresApi
import com.aessam.comeoverhere.core.BluetoothDiscoveryMode
import com.aessam.comeoverhere.core.NearbyAwareState
import com.aessam.comeoverhere.core.NearbyAwareSettings
import com.aessam.comeoverhere.core.WiFiAwareRoomTransport
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.GatewayRoomDescriptor
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.MutableStateFlow

internal interface GatewayTourContext {
    val listenState: StateFlow<ListenState>
    val activeRoomID: String?
    val guideAwareState: StateFlow<NearbyAwareState>
    fun descriptor(): GatewayRoomDescriptor?
    fun setCompanionGuard(guard: () -> Boolean)
    fun suspendDiscovery()
    fun resumeDiscovery()
    fun enableGuideDiscovery()
    fun endGuideDiscovery()
}

internal class AppGatewayTourContext(private val channels: ChannelService) : GatewayTourContext {
    private val discovery = GatewayDiscoveryOwnership(channels.awareSettings,
        { channels.bluetoothDiscoveryEnabled.value }, channels::setBluetoothDiscoveryEnabled)
    override val listenState get() = channels.listenState
    override val activeRoomID get() = channels.activeChannelID.value
    override val guideAwareState = channels.awareSettings?.state ?: MutableStateFlow(NearbyAwareState())
    override fun descriptor() = channels.gatewayGuideDescriptor()
    override fun setCompanionGuard(guard: () -> Boolean) { channels.companionModeActive = guard }
    override fun suspendDiscovery() = discovery.suspend()
    override fun resumeDiscovery() = discovery.resume()
    override fun enableGuideDiscovery() = discovery.beginGuide()
    override fun endGuideDiscovery() = discovery.endGuide()
}

/** Owns only the preference changes made by gateway mode, not the underlying tour. */
internal class GatewayDiscoveryOwnership(private val aware: NearbyAwareSettings?,
    private val bluetoothEnabled: () -> Boolean, private val setBluetoothEnabled: (Boolean) -> Unit) {
    private var guidePriorAware: Boolean? = null
    private var suspended: Pair<Boolean, Boolean?>? = null
    fun beginGuide() {
        val settings = requireNotNull(aware) { "Android guide branch requires supported Wi-Fi Aware (Android 14+)" }
        if (guidePriorAware == null) guidePriorAware = settings.enabledPreference
        settings.setEnabled(true)
    }
    fun endGuide() {
        val prior = guidePriorAware ?: return
        guidePriorAware = null
        // An explicit later user disable supersedes this owner's temporary enable.
        if (aware?.enabledPreference == true) aware.setEnabled(prior)
    }
    fun suspend() {
        if (suspended != null) return
        suspended = bluetoothEnabled() to aware?.enabledPreference
        setBluetoothEnabled(false)
        aware?.setEnabled(false)
    }
    fun resume() {
        val prior = suspended ?: return
        suspended = null
        if (!bluetoothEnabled()) setBluetoothEnabled(prior.first)
        if (aware?.enabledPreference == false) prior.second?.let(aware::setEnabled)
    }
}

internal interface GatewayBranchInterface {
    val state: StateFlow<NearbyAwareState>
    var onError: ((String) -> Unit)?
    fun publish(record: BluetoothRoomRecord)
    fun start()
    fun stop()
}

@RequiresApi(34)
internal class AwareGatewayBranch(private val native: WiFiAwareRoomTransport) : GatewayBranchInterface {
    override val state get() = native.state
    override var onError: ((String) -> Unit)?
        get() = native.onError
        set(value) { native.onError = value }
    override fun publish(record: BluetoothRoomRecord) = native.publish(record)
    override fun start() = native.setMode(BluetoothDiscoveryMode.ADVERTISING)
    override fun stop() = native.stop()
}
