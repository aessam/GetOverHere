package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionMessageKind
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory

class NativeGuestOwnershipTest {
    @Test fun socketFactoryFailureIsReportedWithoutEscapingGuestThread() {
        val guest = LocalSessionControlTransport(ServerSocket(0).use { it.localPort })
        val room = UUID.randomUUID()
        val failure = CountDownLatch(1)
        try {
            guest.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guest.configureSession(room, UUID.randomUUID(), "Guest", ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", room))
            guest.hostIP = "127.0.0.1"
            guest.setGuestSocketFactory(DelayedGuestSocketFactory(java.io.IOException("fixture socket failure")))
            guest.setEventHandler {
                if (it is SessionControlEvent.Failed && it.message.contains("fixture socket failure")) failure.countDown()
            }
            guest.startGuest()
            assertTrue("Socket factory exception escaped the controlled failure path", failure.await(2, TimeUnit.SECONDS))
        } finally { guest.stop() }
    }

    @Test fun lateControlSocketCannotReplaceNewRunSocketOrWriter() {
        val port = ServerSocket(0).use { it.localPort }
        val guide = LocalSessionControlTransport(port)
        val guest = LocalSessionControlTransport(port)
        val factory = DelayedGuestSocketFactory()
        val room = UUID.randomUUID()
        val oldRoom = UUID.randomUUID()
        val credential = SessionCredential.derive("23456789AB", room)
        val connected = CountDownLatch(1)
        val upstream = CountDownLatch(1)
        val downstream = CountDownLatch(1)
        try {
            guest.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guest.configureSession(oldRoom, UUID.randomUUID(), "Old guest", ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", oldRoom))
            guest.hostIP = "127.0.0.1"
            guest.setGuestSocketFactory(factory)
            guest.startGuest()
            assertTrue(factory.entered.await(3, TimeUnit.SECONDS))
            guest.stop()

            guide.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guide.configureSession(room, UUID.randomUUID(), "Guide", ParticipantPlatform.ANDROID, credential)
            guide.setEventHandler { if (it is SessionControlEvent.EnvelopeReceived) upstream.countDown() }
            guide.startGuide()
            guest.configureSession(room, UUID.randomUUID(), "New guest", ParticipantPlatform.ANDROID, credential)
            guest.setGuestSocketFactory(null)
            guest.setEventHandler {
                if (it is SessionControlEvent.Connected) connected.countDown()
                if (it is SessionControlEvent.EnvelopeReceived) downstream.countDown()
            }
            guest.startGuest()
            assertTrue(connected.await(3, TimeUnit.SECONDS))
            factory.release.countDown()
            assertTrue("Superseded socket was not closed", factory.closed.await(3, TimeUnit.SECONDS))
            guest.send(SessionMessageKind.HEARTBEAT, byteArrayOf(1))
            guide.send(SessionMessageKind.HEARTBEAT, byteArrayOf(2))
            assertTrue("Current writer was replaced", upstream.await(3, TimeUnit.SECONDS))
            assertTrue("Current socket was replaced", downstream.await(3, TimeUnit.SECONDS))
        } finally {
            factory.release.countDown()
            guest.stop()
            guide.stop()
        }
    }

    @Test fun lateAudioSocketCannotReplaceNewRunOrReceiveItsPcm() {
        val port = ServerSocket(0).use { it.localPort }
        val guide = UDPAudioPlane(PassThroughRealtimeAudioCodecProvider(), port)
        val guest = UDPAudioPlane(PassThroughRealtimeAudioCodecProvider(), port)
        val factory = DelayedGuestSocketFactory()
        val room = UUID.randomUUID()
        val oldRoom = UUID.randomUUID()
        val credential = SessionCredential.derive("23456789AB", room)
        val joined = CountDownLatch(1)
        val audio = CountDownLatch(1)
        val oldAudio = CountDownLatch(1)
        try {
            guest.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guest.configureSession(oldRoom, UUID.randomUUID(), "Old guest", ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", oldRoom))
            guest.hostIP = "127.0.0.1"
            guest.setGuestSocketFactory(factory)
            guest.startListening(oldRoom.toString()) { oldAudio.countDown() }
            assertTrue(factory.entered.await(3, TimeUnit.SECONDS))
            guest.stop()

            guide.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            guide.configureSession(room, UUID.randomUUID(), "Guide", ParticipantPlatform.ANDROID, credential)
            guide.setSessionEventHandler { if (it is AudioSessionEvent.Joined) joined.countDown() }
            guide.startBroadcasting(room.toString(), AudioQuality.STANDARD)
            guest.configureSession(room, UUID.randomUUID(), "New guest", ParticipantPlatform.ANDROID, credential)
            guest.setGuestSocketFactory(null)
            guest.startListening(room.toString()) { audio.countDown() }
            assertTrue(joined.await(3, TimeUnit.SECONDS))
            factory.release.countDown()
            assertTrue("Superseded socket was not closed", factory.closed.await(3, TimeUnit.SECONDS))
            repeat(3) { guide.sendAudio(byteArrayOf(1, 2, 3, 4)) }
            assertTrue("Current audio socket was replaced", audio.await(3, TimeUnit.SECONDS))
            assertTrue("Old callback received new PCM", oldAudio.count == 1L)
        } finally {
            factory.release.countDown()
            guest.stop()
            guide.stop()
        }
    }
}

/** Deliberately returns after stop/new-start, even when the old audio thread was interrupted. */
private class DelayedGuestSocketFactory(private val createError: java.io.IOException? = null) : SocketFactory() {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val closed = CountDownLatch(1)
    private val delegate = getDefault()
    override fun createSocket(): Socket {
        entered.countDown()
        createError?.let { throw it }
        var interrupted = false
        while (true) {
            try {
                check(release.await(5, TimeUnit.SECONDS)) { "Test did not release delayed socket factory" }
                break
            } catch (_: InterruptedException) {
                interrupted = true
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
        return object : Socket() {
            override fun close() {
                try { super.close() } finally { closed.countDown() }
            }
        }
    }
    override fun createSocket(host: String, port: Int): Socket = delegate.createSocket(host, port)
    override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket =
        delegate.createSocket(host, port, local, localPort)
    override fun createSocket(host: InetAddress, port: Int): Socket = delegate.createSocket(host, port)
    override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket =
        delegate.createSocket(host, port, local, localPort)
}
