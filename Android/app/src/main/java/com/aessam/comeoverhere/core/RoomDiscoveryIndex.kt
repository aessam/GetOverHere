package com.aessam.comeoverhere.core

import java.util.UUID

/** LAN addresses are never accepted from Bluetooth observations. */
internal class RoomDiscoveryIndex {
    enum class Source { LAN, BLUETOOTH, AWARE }
    private val lan = mutableMapOf<String, Pair<BLECommand.ChannelAnnounce, PeerInfo>>()
    private val bluetooth = mutableMapOf<String, Pair<BLECommand.ChannelAnnounce, PeerInfo>>()
    private val aware = mutableMapOf<String, Pair<BLECommand.ChannelAnnounce, PeerInfo>>()
    private fun selected(id: String) = lan[id] ?: aware[id] ?: bluetooth[id]
    private fun table(source: Source) = when (source) { Source.LAN -> lan; Source.AWARE -> aware; Source.BLUETOOTH -> bluetooth }
    val peers: List<PeerInfo> get() = (lan.keys + bluetooth.keys + aware.keys).mapNotNull { selected(it) }
        .map { it.second }.distinctBy { it.id }
    private fun key(id: String): String = try { UUID.fromString(id).toString() }
        catch (error: IllegalArgumentException) { id } // Non-UUID legacy discovery identities remain unchanged.

    fun update(value: BLECommand.ChannelAnnounce, peer: PeerInfo, source: Source): Pair<BLECommand, PeerInfo>? {
        if (source == Source.LAN && value.audioHostIP.isNullOrEmpty()) return remove(value.channelID, source)
        val id = key(value.channelID)
        if (selected(id) == null && (lan.keys + bluetooth.keys + aware.keys).size >= 64) return null
        val entry = value.copy(channelID = id, wifiSSID = null,
            audioHostIP = if (source == Source.LAN) value.audioHostIP else null) to peer
        table(source)[id] = entry
        return selected(id)
    }
    fun remove(id: String, source: Source): Pair<BLECommand, PeerInfo>? {
        val key = key(id)
        val removed = table(source).remove(key) ?: return null
        return selected(key) ?: (BLECommand.ChannelUnavailable(key) to removed.second)
    }
}
