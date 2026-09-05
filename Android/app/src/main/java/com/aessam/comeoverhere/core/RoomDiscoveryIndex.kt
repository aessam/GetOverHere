package com.aessam.comeoverhere.core

import java.util.UUID

/** LAN addresses are never accepted from Bluetooth observations. */
internal class RoomDiscoveryIndex {
    enum class Source { LAN, BLUETOOTH }
    private val lan = mutableMapOf<String, Pair<BLECommand.ChannelAnnounce, PeerInfo>>()
    private val bluetooth = mutableMapOf<String, Pair<BLECommand.ChannelAnnounce, PeerInfo>>()
    val peers: List<PeerInfo> get() = (lan.keys + bluetooth.keys).mapNotNull { lan[it] ?: bluetooth[it] }
        .map { it.second }.distinctBy { it.id }
    private fun key(id: String): String = try { UUID.fromString(id).toString() }
        catch (error: IllegalArgumentException) { id } // Non-UUID legacy discovery identities remain unchanged.

    fun update(value: BLECommand.ChannelAnnounce, peer: PeerInfo, source: Source): Pair<BLECommand, PeerInfo>? {
        if (source == Source.LAN && value.audioHostIP.isNullOrEmpty()) return remove(value.channelID, source)
        val id = key(value.channelID)
        if (id !in lan && id !in bluetooth && (lan.keys + bluetooth.keys).size >= 64) return null
        val entry = value.copy(channelID = id, wifiSSID = null,
            audioHostIP = if (source == Source.LAN) value.audioHostIP else null) to peer
        if (source == Source.LAN) lan[id] = entry else bluetooth[id] = entry
        return lan[id] ?: bluetooth[id]
    }
    fun remove(id: String, source: Source): Pair<BLECommand, PeerInfo>? {
        val key = key(id)
        val removed = (if (source == Source.LAN) lan else bluetooth).remove(key) ?: return null
        return lan[key] ?: bluetooth[key] ?: (BLECommand.ChannelUnavailable(key) to removed.second)
    }
}
