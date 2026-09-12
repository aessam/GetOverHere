package com.aessam.comeoverhere

import android.os.Build
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.core.HubCertificateTrust
import com.aessam.comeoverhere.debug.GatewayDebugControl
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.TrustManager
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Component tests with the actual app-owned services; no physical route claim. */
@RunWith(AndroidJUnit4::class)
class GatewayDebugControlTest {
    private fun withServer(test: (JSONObject) -> Unit) {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val app = ApplicationProvider.getApplicationContext<ComeOverHereApp>()
        val server = GatewayDebugControl(app)
        val file = File(app.filesDir, "debug-control/credentials.json")
        try {
            server.start()
            test(JSONObject(file.readText()))
        } finally { server.stop() }
        assertFalse(file.exists())
    }

    private fun request(credentials: JSONObject, id: String = UUID.randomUUID().toString(),
                        command: String = "status", wrongKey: Boolean = false): JSONObject {
        val key = Base64.decode(credentials.getString("key"), Base64.NO_WRAP)
        if (wrongKey) key[0] = (key[0].toInt() xor 1).toByte()
        val payload = JSONObject().put("id", id).put("command", command).put("arguments", JSONObject()).toString().toByteArray()
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(payload)
        val envelope = JSONObject().put("payload", Base64.encodeToString(payload, Base64.NO_WRAP))
            .put("mac", Base64.encodeToString(mac, Base64.NO_WRAP)).toString().toByteArray()
        val pin = credentials.getString("certificate_sha256").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val context = SSLContext.getInstance("TLSv1.3").apply {
            init(null, arrayOf<TrustManager>(HubCertificateTrust(pin)), SecureRandom())
        }
        return (context.socketFactory.createSocket("127.0.0.1", credentials.getInt("port")) as SSLSocket).use { socket ->
            socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = 5_000; socket.startHandshake()
            DataOutputStream(socket.outputStream).apply { writeInt(envelope.size); write(envelope); flush() }
            val input = DataInputStream(socket.inputStream)
            val size = input.readInt()
            require(size in 1..32768)
            JSONObject(ByteArray(size).also(input::readFully).toString(Charsets.UTF_8))
        }
    }

    @Test fun readsActualApplicationStatusWithPinnedTLSAndAuthenticatedRequest() = withServer { credentials ->
        val result = request(credentials)
        assertTrue(result.getBoolean("success"))
        val status = JSONObject(result.getString("result"))
        val app = ApplicationProvider.getApplicationContext<ComeOverHereApp>()
        assertEquals(app.channelService.localPeerID, status.getString("deviceID"))
        assertEquals(app.audioEngine.acceptedPlaybackByteCount, status.getLong("acceptedPlaybackBytes"))
        assertEquals("unqualified", status.getString("routeEvidence"))
        assertFalse(status.getBoolean("debugKeepAwake"))
    }

    @Test fun rejectsWrongHMACBeforeExecutingCommand() = withServer { credentials ->
        try { request(credentials, wrongKey = true); throw AssertionError("Wrong HMAC accepted") }
        catch (expected: IOException) { assertTrue(request(credentials).getBoolean("success")) }
    }

    @Test fun rejectsReplayedIDAndUnknownCommands() = withServer { credentials ->
        val id = UUID.randomUUID().toString()
        assertTrue(request(credentials, id).getBoolean("success"))
        try { request(credentials, id); throw AssertionError("Replay accepted") }
        catch (expected: IOException) { assertFalse(request(credentials, command = "arbitrary-shell").getBoolean("success")) }
    }

    @Test fun listenerCloseFailureCannotSkipCredentialAndExecutorCleanup() {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val app = ApplicationProvider.getApplicationContext<ComeOverHereApp>()
        var injected = false
        // The real TLS listener closes, then this explicit component fault
        // reproduces an IOException. This is not a simulated physical result.
        val server = GatewayDebugControl(app, closeListener = { socket ->
            socket.close(); injected = true; throw IOException("Injected listener close failure")
        })
        val file = File(app.filesDir, "debug-control/credentials.json")
        try {
            server.start()
            assertTrue(file.exists())
            server.stop()
            assertTrue(injected)
            assertFalse(server.active)
            assertFalse(file.exists())
            val type = server.javaClass
            val key = type.getDeclaredField("key").apply { isAccessible = true }.get(server) as ByteArray
            assertTrue(key.all { it == 0.toByte() })
            for (name in listOf("acceptor", "workers", "timer")) {
                val executor = type.getDeclaredField(name).apply { isAccessible = true }.get(server) as java.util.concurrent.ExecutorService
                assertTrue("$name must shut down after listener failure", executor.isShutdown)
            }
        } finally { server.stop() }
    }

    @Test fun stopDuringNativeStartupRejectsLateListenerAndCredentials() {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val app = ApplicationProvider.getApplicationContext<ComeOverHereApp>()
        val ready = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val nativeListener = AtomicReference<SSLServerSocket>()
        val executor = Executors.newSingleThreadExecutor()
        val server = GatewayDebugControl(app, beforePublication = { socket ->
            nativeListener.set(socket); ready.countDown()
            check(proceed.await(5, TimeUnit.SECONDS)) { "Startup fault latch timed out" }
        })
        try {
            val startup = executor.submit { server.start() }
            assertTrue("Native TLS listener must reach pre-publication latch", ready.await(5, TimeUnit.SECONDS))
            server.stop()
            assertFalse(server.active)
            proceed.countDown()
            try { startup.get(5, TimeUnit.SECONDS); throw AssertionError("Stopped activation published a late listener") }
            catch (expected: ExecutionException) { assertTrue(expected.cause is IllegalStateException) }
            assertTrue(nativeListener.get().isClosed)
            for (name in listOf("credentials.json", "credentials.tmp")) {
                assertFalse(File(app.filesDir, "debug-control/$name").exists())
            }
            for (name in listOf("acceptor", "workers", "timer")) {
                val owned = server.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(server) as java.util.concurrent.ExecutorService
                assertTrue("$name must remain shut down after late startup", owned.isShutdown)
            }
        } finally { proceed.countDown(); server.stop(); executor.shutdownNow() }
    }
}
