package com.aessam.comeoverhere.core

import android.annotation.SuppressLint
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.NetworkInterface
import java.util.UUID

/**
 * Serverless local-LAN discovery using Android NSD.
 * Each live channel is advertised as a `_goh-audio._tcp` service on the local network.
 */
@SuppressLint("NewApi")
class LocalControlPlane(
    context: Context,
    displayName: String
) : ControlPlane {

    override val localPeer = PeerInfo(
        id = UUID.randomUUID().toString(),
        displayName = displayName,
        platform = PeerInfo.Platform.ANDROID
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val callbackExecutor = java.util.concurrent.Executor { command ->
        android.os.Handler(android.os.Looper.getMainLooper()).post(command)
    }
    private val serviceCallbacks = mutableMapOf<String, NsdManager.ServiceInfoCallback>()
    private val desiredAnnouncements = mutableMapOf<String, BLECommand.ChannelAnnounce>()
    private val updatingRegistrations = mutableSetOf<String>()
    private val legacyServices = mutableMapOf<String, NsdServiceInfo>()
    private val legacyHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var legacyResolveInFlight = false
    private var legacyResolveIndex = 0
    private val legacyRefresh = object : Runnable {
        override fun run() {
            val services = legacyServices.values.toList()
            if (!legacyResolveInFlight && services.isNotEmpty()) {
                legacyResolveInFlight = true
                val service = services[legacyResolveIndex++ % services.size]
                nsdManager.resolveService(service, resolveListener(service.serviceName))
            }
            legacyHandler.postDelayed(this, 2_000)
        }
    }

    private val _connectedPeers = MutableStateFlow<List<PeerInfo>>(emptyList())
    override val connectedPeers: StateFlow<List<PeerInfo>> = _connectedPeers.asStateFlow()

    private val _commands = MutableSharedFlow<Pair<BLECommand, PeerInfo>>(extraBufferCapacity = 64)
    override val commands: SharedFlow<Pair<BLECommand, PeerInfo>> = _commands.asSharedFlow()

    private val _peerEvents = MutableSharedFlow<PeerEvent>(extraBufferCapacity = 32)
    override val peerEvents: SharedFlow<PeerEvent> = _peerEvents.asSharedFlow()

    private val publishedServices = mutableMapOf<String, Pair<NsdServiceInfo, NsdManager.RegistrationListener>>()
    private val peerByChannelID = mutableMapOf<String, PeerInfo>()

    companion object {
        private const val TAG = "LocalControlPlane"
        private const val SERVICE_TYPE = "_goh-audio._tcp"
        private const val AUDIO_PORT = 50000
        private const val TXT_CHANNEL_NAME = "chname"
        private const val TXT_CREATED_BY = "createdBy"
        private const val TXT_CREATOR_NAME = "crname"
        private const val TXT_AUDIO_QUALITY = "quality"
        private const val TXT_PLATFORM = "platform"
    }

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Discovery failed: $errorCode")
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Discovery stop failed: $errorCode")
        }

        override fun onDiscoveryStarted(serviceType: String) {
            Log.i(TAG, "Local control plane started")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            Log.i(TAG, "Local control plane stopped")
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            if (normalizeServiceType(serviceInfo.serviceType) != normalizeServiceType(SERVICE_TYPE)) return
            if (publishedServices.containsKey(serviceInfo.serviceName)) return
            Log.i(TAG, "Found local service")
            if (Build.VERSION.SDK_INT >= 34) {
                if (serviceCallbacks.containsKey(serviceInfo.serviceName)) return
                val callback = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceUpdated(info: NsdServiceInfo) {
                        resolveListener(serviceInfo.serviceName).onServiceResolved(info)
                    }
                    override fun onServiceLost() = Unit // DiscoveryListener owns removal.
                    override fun onServiceInfoCallbackUnregistered() = Unit
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                        serviceCallbacks.remove(serviceInfo.serviceName)
                        Log.e(TAG, "Service monitoring failed: $errorCode")
                    }
                }
                serviceCallbacks[serviceInfo.serviceName] = callback
                nsdManager.registerServiceInfoCallback(serviceInfo, callbackExecutor, callback)
            } else {
                legacyServices[serviceInfo.serviceName] = serviceInfo
            }
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            legacyServices.remove(serviceInfo.serviceName)
            if (Build.VERSION.SDK_INT >= 34) {
                serviceCallbacks.remove(serviceInfo.serviceName)?.let(nsdManager::unregisterServiceInfoCallback)
            }
            val peer = peerByChannelID.remove(serviceInfo.serviceName) ?: return
            _connectedPeers.value = _connectedPeers.value.filter { it.id != peer.id }
            _peerEvents.tryEmit(PeerEvent.Disconnected(peer))
            _commands.tryEmit(BLECommand.ChannelUnavailable(channelID = serviceInfo.serviceName) to peer)
        }
    }

    override fun start() {
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        if (Build.VERSION.SDK_INT < 34) legacyHandler.post(legacyRefresh)
    }

    override fun stop() {
        legacyHandler.removeCallbacks(legacyRefresh)
        legacyServices.clear()
        legacyResolveInFlight = false
        desiredAnnouncements.clear()
        updatingRegistrations.clear()
        if (Build.VERSION.SDK_INT >= 34) serviceCallbacks.values.forEach(nsdManager::unregisterServiceInfoCallback)
        serviceCallbacks.clear()
        try {
            nsdManager.stopServiceDiscovery(discoveryListener)
        } catch (error: Exception) {
                Log.w(TAG, "Failed to stop local service discovery (${error.javaClass.simpleName})")
        }
        publishedServices.values.forEach { (_, listener) ->
            try {
                nsdManager.unregisterService(listener)
            } catch (error: Exception) {
                Log.w(TAG, "Failed to unregister local service (${error.javaClass.simpleName})")
            }
        }
        publishedServices.clear()
        peerByChannelID.clear()
        _connectedPeers.value = emptyList()
    }

    override fun broadcast(command: BLECommand) {
        when (command) {
            is BLECommand.ChannelAnnounce -> publishChannel(command)
            is BLECommand.ChannelEnded -> unpublishChannel(command.channelID)
            else -> Unit
        }
    }

    override fun send(command: BLECommand, to: PeerInfo) {
        broadcast(command)
    }

    private fun publishChannel(announce: BLECommand.ChannelAnnounce) {
        desiredAnnouncements[announce.channelID] = announce
        if (updatingRegistrations.contains(announce.channelID)) return
        publishedServices[announce.channelID]?.let { (info, listener) ->
            val lock = if (announce.isRoomLocked == false) "0" else "1"
            if (info.attributes["locked"]?.decodeToString() == lock) return
            updatingRegistrations.add(announce.channelID)
            try {
                nsdManager.unregisterService(listener)
            } catch (error: Exception) {
                updatingRegistrations.remove(announce.channelID)
                Log.e(TAG, "Cannot update room discovery (${error.javaClass.simpleName})")
            }
            return
        }

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = announce.channelID
            serviceType = SERVICE_TYPE
            port = AUDIO_PORT
            setAttribute(TXT_CHANNEL_NAME, announce.channelName)
            setAttribute(TXT_CREATED_BY, announce.createdBy)
            setAttribute(TXT_CREATOR_NAME, localPeer.displayName)
            setAttribute(TXT_AUDIO_QUALITY, announce.audioQuality.rawValue)
            setAttribute(TXT_PLATFORM, localPeer.platform.rawValue)
            setAttribute("admission", (announce.roomAdmissionVersion ?: 0).toString())
            setAttribute("locked", if (announce.isRoomLocked == false) "0" else "1")
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "Published local channel")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                publishedServices.remove(announce.channelID)
                Log.e(TAG, "Register failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                if (updatingRegistrations.remove(announce.channelID)) {
                    publishedServices.remove(announce.channelID)
                    desiredAnnouncements[announce.channelID]?.let(::publishChannel)
                }
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                updatingRegistrations.remove(announce.channelID)
                Log.e(TAG, "Unregister failed: $errorCode")
            }
        }

        publishedServices[announce.channelID] = serviceInfo to listener
        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun unpublishChannel(channelID: String) {
        desiredAnnouncements.remove(channelID)
        if (updatingRegistrations.contains(channelID)) return
        val (_, listener) = publishedServices.remove(channelID) ?: return
        try {
            nsdManager.unregisterService(listener)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to unpublish channel (${error.javaClass.simpleName})")
        }
    }

    private fun resolveListener(channelID: String) = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            legacyResolveInFlight = false
            Log.e(TAG, "Resolve failed: $errorCode")
        }

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            legacyResolveInFlight = false
            val createdBy = serviceInfo.attributes[TXT_CREATED_BY]?.decodeToString() ?: return
            if (createdBy == localPeer.id) return
            val creatorName = serviceInfo.attributes[TXT_CREATOR_NAME]?.decodeToString() ?: "Peer"
            val channelName = serviceInfo.attributes[TXT_CHANNEL_NAME]?.decodeToString() ?: serviceInfo.serviceName
            val quality = serviceInfo.attributes[TXT_AUDIO_QUALITY]?.decodeToString()?.let(AudioQuality::fromRaw) ?: AudioQuality.STANDARD
            val platform = serviceInfo.attributes[TXT_PLATFORM]?.decodeToString()?.let(PeerInfo.Platform::fromRaw) ?: PeerInfo.Platform.ANDROID
            val hostIP = if (Build.VERSION.SDK_INT >= 34) {
                serviceInfo.hostAddresses.firstOrNull { it is java.net.Inet4Address }?.hostAddress
            } else serviceInfo.host?.hostAddress
            Log.i(TAG, "Resolved local channel")

            val peer = PeerInfo(id = createdBy, displayName = creatorName, platform = platform)
            peerByChannelID[channelID] = peer
            if (_connectedPeers.value.none { it.id == peer.id }) {
                _connectedPeers.value = _connectedPeers.value + peer
                _peerEvents.tryEmit(PeerEvent.Connected(peer))
            }

            _commands.tryEmit(
                BLECommand.ChannelAnnounce(
                    channelID = serviceInfo.serviceName,
                    channelName = channelName,
                    createdBy = createdBy,
                    audioQuality = quality,
                    wifiSSID = null,
                    audioHostIP = hostIP,
                    roomAdmissionVersion = serviceInfo.attributes["admission"]?.decodeToString()?.toIntOrNull(),
                    isRoomLocked = serviceInfo.attributes["locked"]?.decodeToString() != "0",
                ) to peer
            )
        }
    }

    private fun normalizeServiceType(type: String?): String = type?.trimEnd('.') ?: ""
}
