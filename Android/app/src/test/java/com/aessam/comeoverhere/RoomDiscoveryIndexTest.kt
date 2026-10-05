package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.PeerInfo
import com.aessam.comeoverhere.core.RoomDiscoveryIndex
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoomDiscoveryIndexTest {
    @Test fun threeSourcesFallBackWithoutInventingAnAddress() {
        val index = RoomDiscoveryIndex()
        index.update(value.copy(channelName = "Bluetooth"), peer, RoomDiscoveryIndex.Source.BLUETOOTH)
        index.update(value.copy(channelName = "Aware"), peer, RoomDiscoveryIndex.Source.AWARE)
        val lan = index.update(value, peer, RoomDiscoveryIndex.Source.LAN)!!.first as BLECommand.ChannelAnnounce
        assertEquals("192.0.2.1", lan.audioHostIP)
        val aware = index.remove(value.channelID, RoomDiscoveryIndex.Source.LAN)!!.first as BLECommand.ChannelAnnounce
        assertEquals("Aware", aware.channelName); assertNull(aware.audioHostIP)
        val bluetooth = index.remove(value.channelID, RoomDiscoveryIndex.Source.AWARE)!!.first as BLECommand.ChannelAnnounce
        assertEquals("Bluetooth", bluetooth.channelName); assertNull(bluetooth.audioHostIP)
        assertTrue(index.remove(value.channelID, RoomDiscoveryIndex.Source.BLUETOOTH)!!.first is BLECommand.ChannelUnavailable)
        assertTrue(index.peers.isEmpty())
    }
    @Test fun unresolvedLANIsNotMislabelledAsBluetooth() {
        val index = RoomDiscoveryIndex()
        assertNull(index.update(value.copy(audioHostIP = null), peer, RoomDiscoveryIndex.Source.LAN))
        assertTrue(index.peers.isEmpty())
    }
    private val peer = PeerInfo(UUID.randomUUID().toString(), "Guide")
    private val value = BLECommand.ChannelAnnounce(UUID.randomUUID().toString(), "Room", peer.id,
        AudioQuality.STANDARD, null, "192.0.2.1")
    @Test fun bluetoothCannotOverwriteLANAndLossFallsBack() {
        val index = RoomDiscoveryIndex()
        fun address(result: Pair<BLECommand, PeerInfo>?) = (result!!.first as BLECommand.ChannelAnnounce).audioHostIP
        assertNull(address(index.update(value, peer, RoomDiscoveryIndex.Source.BLUETOOTH)))
        assertEquals("192.0.2.1", address(index.update(value, peer, RoomDiscoveryIndex.Source.LAN)))
        assertEquals("192.0.2.1", address(index.update(value, peer, RoomDiscoveryIndex.Source.BLUETOOTH)))
        assertEquals(1, index.peers.size)
        assertNull(address(index.remove(value.channelID.uppercase(), RoomDiscoveryIndex.Source.LAN)))
        assertTrue(index.remove(value.channelID, RoomDiscoveryIndex.Source.BLUETOOTH)!!.first is BLECommand.ChannelUnavailable)
        assertTrue(index.peers.isEmpty())
    }
    @Test fun bluetoothLossDoesNotRemoveLAN() {
        val index = RoomDiscoveryIndex()
        index.update(value, peer, RoomDiscoveryIndex.Source.BLUETOOTH)
        index.update(value, peer, RoomDiscoveryIndex.Source.LAN)
        val result = index.remove(value.channelID, RoomDiscoveryIndex.Source.BLUETOOTH)!!.first as BLECommand.ChannelAnnounce
        assertEquals("192.0.2.1", result.audioHostIP)
    }
}
