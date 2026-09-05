package com.aessam.comeoverhere

import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.BluetoothRoomDiscoveryInterface
import com.aessam.comeoverhere.core.LocalControlPlane
import com.aessam.toursession.BluetoothRoomRecord
import java.util.UUID
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BluetoothDiscoveryIntegrationTest {
    @Test fun productionDiscoveryForwardsBluetoothMetadataWithoutAnAddress() = runBlocking {
        val radio = DiscoveryRadio()
        val plane = LocalControlPlane(InstrumentationRegistry.getInstrumentation().targetContext, "Guest", radio)
        val observation = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(2_000) { plane.commands.first() } }
        val record = BluetoothRoomRecord(UUID.randomUUID(), UUID.randomUUID(), "Bluetooth room", false, true)
        radio.onRoom?.invoke(record)
        val value = observation.await().first as BLECommand.ChannelAnnounce
        assertEquals(record.roomID.toString(), value.channelID)
        assertEquals(record.name, value.channelName)
        assertEquals(true, value.isRoomLocked)
        assertNull(value.audioHostIP)
    }
    private class DiscoveryRadio : BluetoothRoomDiscoveryInterface {
        override var onRoom: ((BluetoothRoomRecord) -> Unit)? = null
        override var onLost: ((UUID) -> Unit)? = null
        override fun start() = Unit
        override fun stop() = Unit
        override fun publish(record: BluetoothRoomRecord?) = Unit
    }
}
