package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * FND-8 (DSCN-26): only an AEAD authentication failure is a credential rejection. A guide that
 * closes the socket before the challenge is a transport failure and keeps the reconnect path.
 */
class GuestHandshakeOutcomeTest {
    @Test
    fun handshakeEOFIsTransportFailureNotCredentialRejection() {
        val port = 50_042
        val server = ServerSocket(port)
        val serverThread = Thread {
            while (!server.isClosed) {
                try {
                    server.accept().close()
                } catch (error: Exception) {
                    System.err.println("outcome server stopped (${error.javaClass.simpleName})")
                    break
                }
            }
        }.apply {
            isDaemon = true
            start()
        }
        val guest = LocalSessionControlTransport(port)
        val sessionID = UUID.randomUUID()
        val failed = CountDownLatch(1)
        val rejected = CountDownLatch(1)
        val message = AtomicReference<String>()
        try {
            guest.hostIP = "127.0.0.1"
            guest.configureGuideAuthentication(com.aessam.comeoverhere.core.SessionGuideAuthentication.LegacyFixture)
            guest.configureSession(
                sessionID,
                UUID.randomUUID(),
                "Guest",
                ParticipantPlatform.ANDROID,
                SessionCredential.derive("23456789AB", sessionID),
            )
            guest.setEventHandler { event ->
                when (event) {
                    is SessionControlEvent.Failed -> {
                        message.set(event.message)
                        failed.countDown()
                    }
                    is SessionControlEvent.CredentialRejected -> rejected.countDown()
                    else -> Unit
                }
            }
            guest.startGuest()

            assertTrue("EOF must surface as a transport failure", failed.await(3, TimeUnit.SECONDS))
            assertTrue(message.get(), message.get().contains("guide connection failed"))
            assertFalse("EOF must never be classified as a credential rejection", rejected.await(500, TimeUnit.MILLISECONDS))
        } finally {
            guest.stop()
            server.close()
            serverThread.join(1_000)
        }
    }
}
