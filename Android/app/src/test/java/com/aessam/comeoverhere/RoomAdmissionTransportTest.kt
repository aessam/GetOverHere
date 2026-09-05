package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.RoomAdmissionTransport
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.parseBLECommand
import com.aessam.comeoverhere.core.toJson
import com.aessam.toursession.RoomAccessPolicy
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class RoomAdmissionTransportTest {
    @Test fun discoveryRoundtrip() {
        listOf(false, true).forEach { locked ->
            val announce = BLECommand.ChannelAnnounce(UUID.randomUUID().toString(), "Room", UUID.randomUUID().toString(),
                AudioQuality.STANDARD, null, "127.0.0.1", 1, locked)
            assertEquals(announce, parseBLECommand(announce.toJson()))
        }
        val legacy = """{"channelAnnounce":{"channelID":"legacy","channelName":"Room","createdBy":"guide","audioQuality":"standard"}}"""
        val old = parseBLECommand(legacy.toByteArray()) as BLECommand.ChannelAnnounce
        assertEquals(null, old.roomAdmissionVersion)
        assertEquals(null, old.isRoomLocked)
    }

    @Test fun lockEditUnlockPreservesMediaSecret() {
        val id = UUID.randomUUID()
        val transport = RoomAdmissionTransport(56003)
        try {
            transport.start(id, "23456789AB")
            assertEquals("23456789AB", transport.join("127.0.0.1", id, null))
            transport.update(RoomAccessPolicy(id, "1234"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, null) }
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, "wrong") }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, "1234"))
            transport.update(RoomAccessPolicy(id, "Edited!"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, "1234") }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, "Edited!"))
            transport.update(RoomAccessPolicy(id, null))
            assertEquals("23456789AB", transport.join("127.0.0.1", id, null))
        } finally { transport.stop() }
    }
}
