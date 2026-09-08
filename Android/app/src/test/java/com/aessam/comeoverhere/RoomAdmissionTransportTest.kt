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
    @Test(timeout = 3_000) fun fullSocketRejectsReplyWithoutWaiting() {
        java.nio.channels.ServerSocketChannel.open().use { listener ->
            listener.socket().bind(java.net.InetSocketAddress("127.0.0.1", 0))
            java.nio.channels.SocketChannel.open().use { guest ->
                guest.socket().receiveBufferSize = 1_024
                guest.connect(listener.localAddress)
                listener.accept().use { guide ->
                    guide.socket().sendBufferSize = 1_024
                    guide.configureBlocking(false)
                    val reply = ByteArray(com.aessam.toursession.RoomAdmissionV2.REPLY_SIZE)
                    var rejected = false
                    val start = System.nanoTime()
                    for (index in 0..<100_000) {
                        try { RoomAdmissionTransport.writeReplyOnce(guide, reply) }
                        catch (error: IllegalStateException) {
                            assertEquals("Room admission reply backpressured.", error.message)
                            rejected = true; break
                        }
                    }
                    org.junit.Assert.assertTrue("Socket never backpressured", rejected)
                    org.junit.Assert.assertTrue("Reply waited for peer", System.nanoTime() - start < 1_000_000_000L)
                }
            }
        }
    }

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
            transport.start(id, "23456789AB", com.aessam.toursession.GuideFrameSigner(id, id))
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, null).mediaSecret)
            transport.update(RoomAccessPolicy(id, "1234"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, id, null).mediaSecret }
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, id, "wrong").mediaSecret }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, "1234").mediaSecret)
            transport.update(RoomAccessPolicy(id, "Edited!"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, id, "1234").mediaSecret }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, "Edited!").mediaSecret)
            transport.update(RoomAccessPolicy(id, null))
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, null).mediaSecret)
        } finally { transport.stop() }
    }
}
