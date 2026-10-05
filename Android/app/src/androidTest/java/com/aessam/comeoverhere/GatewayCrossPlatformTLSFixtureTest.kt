package com.aessam.comeoverhere

import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.core.HubIdentity
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.KeyStore
import java.security.MessageDigest
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/** Test-only controller fixture. Real TLS through ADB is NOT physical USB/radio evidence. */
@RunWith(AndroidJUnit4::class)
class GatewayCrossPlatformTLSFixtureTest {
    @Test fun controlledExchange() {
        val arguments = InstrumentationRegistry.getArguments()
        val run = arguments.getString("gatewayTlsRun")
        assumeTrue("Explicit interop controller required", run != null)
        requireNotNull(run)
        require(Regex("[a-f0-9]{32}").matches(run))
        val alias = "goh.test.interop.$run"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val mode = requireNotNull(arguments.getString("gatewayTlsMode"))
        if (mode == "cleanup") { store.deleteEntry(alias); return }
        val identity = HubIdentity(alias)
        if (mode == "identity") {
            status("GATEWAY_PIN=" + identity.fingerprint.joinToString("") { "%02x".format(it) })
            return
        }
        try {
            val expected = requireNotNull(arguments.getString("gatewayTlsPin"))
            require(Regex("[a-f0-9]{64}").matches(expected))
            val pin = expected.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val port = requireNotNull(arguments.getString("gatewayTlsPort")).toInt()
            require(port in 1024..65535)
            val context = identity.context(pin)
            if (mode == "server") {
                (context.serverSocketFactory.createServerSocket() as SSLServerSocket).use { listener ->
                    listener.enabledProtocols = arrayOf("TLSv1.3"); listener.needClientAuth = true
                    listener.soTimeout = 15_000
                    listener.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port))
                    status("GATEWAY_SERVER_READY")
                    (listener.accept() as SSLSocket).use { exchange(it, server = true) }
                }
            } else {
                require(mode == "client")
                (context.socketFactory.createSocket() as SSLSocket).use { socket ->
                    socket.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 10_000)
                    exchange(socket, server = false)
                }
            }
        } finally { store.deleteEntry(alias) }
    }

    private fun exchange(socket: SSLSocket, server: Boolean) {
        socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = 10_000; socket.tcpNoDelay = true
        socket.startHandshake(); assertEquals("TLSv1.3", socket.session.protocol)
        val input = DataInputStream(socket.inputStream); val output = DataOutputStream(socket.outputStream)
        val expected = ByteArray(65_536) { (it % 251).toByte() }
        if (!server) { output.writeInt(expected.size); output.write(expected); output.flush() }
        assertEquals(expected.size, input.readInt())
        val received = ByteArray(expected.size).also(input::readFully)
        assertArrayEquals(expected, received)
        if (server) {
            output.writeInt(received.size); output.write(received); output.flush()
            assertEquals(42, input.readUnsignedByte())
        } else { output.writeByte(42); output.flush() }
        status("GATEWAY_PASS bytes=${received.size} sha256=" +
            MessageDigest.getInstance("SHA-256").digest(received).joinToString("") { "%02x".format(it) })
    }

    private fun status(message: String) {
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", "$message\n") })
    }
}
