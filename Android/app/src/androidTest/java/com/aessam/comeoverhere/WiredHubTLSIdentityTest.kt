package com.aessam.comeoverhere

import androidx.test.ext.junit.runners.AndroidJUnit4
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.aessam.comeoverhere.core.HubIdentity
import com.aessam.comeoverhere.core.HubCertificateTrust
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.KeyStore
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.TrustManager

/** Real AndroidKeyStore + JSSE on emulator/device. Loopback is explicitly not USB qualification. */
@RunWith(AndroidJUnit4::class)
class WiredHubTLSIdentityTest {
    @Test fun missingClientCertificateCannotOpenHubConnection() = identities { guide, companion ->
        val server = guide.context(companion.fingerprint).serverSocketFactory.createServerSocket() as SSLServerSocket
        server.enabledProtocols = arrayOf("TLSv1.3"); server.needClientAuth = true; server.soTimeout = 5_000
        server.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
        val worker = Executors.newSingleThreadExecutor()
        val rejected = worker.submit<Boolean> {
            (server.accept() as SSLSocket).use { peer ->
                peer.soTimeout = 5_000
                try { peer.startHandshake(); false } catch (error: SSLException) { true }
            }
        }
        try {
            val anonymous = SSLContext.getInstance("TLSv1.3").apply {
                init(emptyArray(), arrayOf<TrustManager>(HubCertificateTrust(guide.fingerprint)), null)
            }
            (anonymous.socketFactory.createSocket() as SSLSocket).use { client ->
                client.enabledProtocols = arrayOf("TLSv1.3"); client.soTimeout = 5_000
                client.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), 5_000)
                try { client.startHandshake(); client.outputStream.write(42); client.inputStream.read() }
                catch (error: SSLException) { /* The server result below is the required rejection evidence. */ }
            }
            assertTrue("Hub server accepted an anonymous client", rejected.get(6, TimeUnit.SECONDS))
        } finally { server.close(); worker.shutdownNow() }
    }

    @Test fun incompatibleExistingIdentityFailsWithoutRotatingItsCertificate() {
        val alias = "goh.test.old-policy.${UUID.randomUUID()}"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        try {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256).build())
                generateKeyPair()
            }
            val before = store.getCertificate(alias).encoded
            val failure = runCatching { HubIdentity(alias) }.exceptionOrNull()
            assertTrue(failure?.message.orEmpty().contains("not rotated"))
            assertArrayEquals(before, store.getCertificate(alias).encoded)
        } finally { store.deleteEntry(alias) }
    }

    @Test fun mutuallyPinnedTLS13RoundTripsRealBytes() = identities { guide, companion ->
        exchange(guide, companion, wrongGuidePin = false)
    }

    @Test fun wrongCertificatePinRejectsHandshake() = identities { guide, companion ->
        exchange(guide, companion, wrongGuidePin = true)
    }

    private fun exchange(guide: HubIdentity, companion: HubIdentity, wrongGuidePin: Boolean) {
        val executor = Executors.newSingleThreadExecutor()
        val server = guide.context(companion.fingerprint).serverSocketFactory.createServerSocket() as SSLServerSocket
        server.enabledProtocols = arrayOf("TLSv1.3"); server.needClientAuth = true; server.soTimeout = 5_000
        server.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
        val result = executor.submit<String> {
            (server.accept() as SSLSocket).use { peer ->
                peer.soTimeout = 5_000; peer.startHandshake()
                assertEquals(42, peer.inputStream.read()); peer.outputStream.write(99); peer.outputStream.flush()
                peer.session.protocol
            }
        }
        try {
            val pin = if (wrongGuidePin) ByteArray(32) else guide.fingerprint
            var rejected = false
            try {
                (companion.context(pin).socketFactory.createSocket() as SSLSocket).use { client ->
                    client.enabledProtocols = arrayOf("TLSv1.3"); client.soTimeout = 5_000
                    client.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), 5_000)
                    client.startHandshake()
                    client.outputStream.write(42); client.outputStream.flush()
                    assertEquals(99, client.inputStream.read())
                    assertEquals("TLSv1.3", client.session.protocol)
                }
            } catch (error: javax.net.ssl.SSLException) {
                if (!wrongGuidePin) {
                    try { result.get(2, TimeUnit.SECONDS) }
                    catch (serverError: Exception) { error.addSuppressed(serverError) }
                    throw error
                }
                rejected = true
            }
            if (wrongGuidePin) assertTrue("Wrong pinned certificate must fail", rejected)
            else assertEquals("TLSv1.3", result.get(6, TimeUnit.SECONDS))
        } finally { server.close(); executor.shutdownNow() }
    }

    private fun identities(test: (HubIdentity, HubIdentity) -> Unit) {
        val aliases = listOf("goh.test.guide.${UUID.randomUUID()}", "goh.test.companion.${UUID.randomUUID()}")
        try { test(HubIdentity(aliases[0]), HubIdentity(aliases[1])) }
        finally {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            aliases.forEach(store::deleteEntry)
        }
    }
}
