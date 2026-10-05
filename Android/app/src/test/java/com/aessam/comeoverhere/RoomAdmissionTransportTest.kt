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
import org.junit.Assert.assertFalse
import com.aessam.comeoverhere.core.RoomAdmissionTransportError
import org.junit.Test

class RoomAdmissionTransportTest {
    @Test(timeout = 5_000) fun refusedConnectionIsTypedReachabilityFailure() {
        val port = java.net.ServerSocket(0).use { it.localPort }
        assertThrows(RoomAdmissionTransportError::class.java) {
            RoomAdmissionTransport(port).join("127.0.0.1", UUID.randomUUID(), UUID.randomUUID(), null)
        }
    }

    @Test(timeout = 5_000) fun emptyChallengeDisconnectIsReachabilityButTruncatedChallengeIsTerminal() {
        listOf(0, 1, 102).forEach { length ->
            val error = failureFromPeer { socket -> socket.getOutputStream().write(ByteArray(length)) }
            assertEquals("challenge bytes=$length", length == 0, error is RoomAdmissionTransportError)
        }
    }

    @Test(timeout = 5_000) fun completeMalformedChallengeIsNeverAReachabilityFailure() {
        val error = failureFromPeer { socket -> socket.getOutputStream().write(ByteArray(com.aessam.toursession.RoomAdmissionV2.CHALLENGE_SIZE)) }
        assertFalse(error is RoomAdmissionTransportError)
        org.junit.Assert.assertTrue(error is IllegalArgumentException)
    }

    @Test(timeout = 5_000) fun replyDisconnectAfterCredentialRequestIsNeverAReachabilityFailure() {
        val room = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val signer = com.aessam.toursession.GuideFrameSigner(room, guideID)
        val guide = com.aessam.toursession.RoomAdmissionV2.Guide(room, RoomAccessPolicy(room, null), signer)
        val error = failureFromPeer(room, guideID) { socket ->
            socket.getOutputStream().write(guide.challenge)
            java.io.DataInputStream(socket.getInputStream()).readFully(ByteArray(com.aessam.toursession.RoomAdmissionV2.REQUEST_SIZE))
        }
        assertFalse(error is RoomAdmissionTransportError)
        org.junit.Assert.assertTrue(error is java.io.EOFException)
    }

    private fun failureFromPeer(room: UUID = UUID.randomUUID(), guide: UUID = UUID.randomUUID(),
        serve: (java.net.Socket) -> Unit): Exception = java.net.ServerSocket(0).use { server ->
        val failures = java.util.concurrent.CopyOnWriteArrayList<Throwable>()
        val thread = kotlin.concurrent.thread(isDaemon = true) {
            try { server.accept().use { it.soTimeout = 2_000; serve(it) } }
            catch (error: Exception) { failures += error }
        }
        val error = assertThrows(Exception::class.java) { RoomAdmissionTransport(server.localPort).join("127.0.0.1", room, guide, null) }
        thread.join(2_000)
        org.junit.Assert.assertFalse("Peer fixture did not terminate", thread.isAlive)
        org.junit.Assert.assertTrue("Peer fixture failed: $failures", failures.isEmpty())
        error
    }

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
            assertFalse(assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, id, null).mediaSecret } is RoomAdmissionTransportError)
            assertFalse(assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, id, "wrong").mediaSecret } is RoomAdmissionTransportError)
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, "1234").mediaSecret)
            transport.update(RoomAccessPolicy(id, "Edited!"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, id, "1234").mediaSecret }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, "Edited!").mediaSecret)
            transport.update(RoomAccessPolicy(id, null))
            assertEquals("23456789AB", transport.join("127.0.0.1", id, id, null).mediaSecret)
        } finally { transport.stop() }
    }
}
