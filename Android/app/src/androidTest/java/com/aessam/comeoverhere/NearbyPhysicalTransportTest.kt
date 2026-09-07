package com.aessam.comeoverhere

import android.os.Build
import android.Manifest
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.BluetoothDiscoveryMode
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.NearbySocketBridge
import com.aessam.comeoverhere.core.RoomAdmissionTransport
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.comeoverhere.core.WiFiAwareRoomTransport
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.TourVisualMode
import com.aessam.toursession.VisualFocusSnapshotPayload
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.sin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit two-device fixture. A normal emulator suite skips it; no radio claim comes from that skip. */
@RunWith(AndroidJUnit4::class)
class NearbyPhysicalTransportTest {
    @get:Rule val permissions: GrantPermissionRule = GrantPermissionRule.grant(*(
        BluetoothRoomDiscovery.requiredPermissions().toList() +
            if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.NEARBY_WIFI_DEVICES) else emptyList()
        ).toTypedArray())

    @Test fun bluetoothCarriesRealAdmissionControlAssetsAndNativeAudio() {
        val args = InstrumentationRegistry.getArguments()
        val role = args.getString("nearbyRole")
        assumeTrue("Requires explicit physical guide/guest pair", role == "guide" || role == "guest")
        assumeTrue("LE credit-based sockets require Android 10+", Build.VERSION.SDK_INT >= 29)
        val room = UUID.fromString(requireNotNull(args.getString("nearbyRoom")))
        val guideID = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val participant = if (role == "guide") guideID else UUID.randomUUID()
        val useAware = args.getString("nearbyTransport") == "aware"
        check(!useAware || Build.VERSION.SDK_INT >= 34)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // This fixture qualifies foreground sessions. Do not let installation/long codec gates
        // turn it accidentally into an unlabelled locked-phone discovery experiment.
        val activity = ActivityScenario.launch(MainActivity::class.java).onActivity {
            it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            it.setTurnScreenOn(true)
        }
        lateinit var radio: BluetoothRoomDiscovery
        var aware: WiFiAwareRoomTransport? = null
        val pairingScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        instrumentation.runOnMainSync {
            radio = BluetoothRoomDiscovery(instrumentation.targetContext)
            if (useAware) aware = WiFiAwareRoomTransport(instrumentation.targetContext) {
                requireNotNull(args.getString("nearbyDevicePIN"))
            }
        }
        val bridge = NearbySocketBridge()
        bridge.onError = { Log.w("NearbyPhysical", "Adapter: $it") }
        val admission = RoomAdmissionTransport()
        val audio = UDPAudioPlane()
        val control = LocalSessionControlTransport()
        val asset = LocalSessionAssetTransport()
        val assetBytes = ByteArray(512) { (it % 251).toByte() }
        val assetHash = MessageDigest.getInstance("SHA-256").digest(assetBytes).joinToString("") { "%02x".format(it) }
        val chunk = AssetChunkPayload(assetHash, 0, assetBytes.size.toLong(), assetBytes)
        try {
            val credential: SessionCredential
            if (role == "guide") {
                admission.start(room, "23456789AB")
                admission.update(RoomAccessPolicy(room, "2468"))
                credential = SessionCredential.derive("23456789AB", room)
            } else {
                val discovered = CountDownLatch(1)
                instrumentation.runOnMainSync {
                    val nativeAware = aware
                    if (nativeAware != null) {
                        nativeAware.onRoom = { if (it.roomID == room) discovered.countDown() }
                        nativeAware.onError = { Log.w("NearbyPhysical", "Aware: $it") }
                        nativeAware.setMode(BluetoothDiscoveryMode.BROWSING)
                        pairingScope.launch {
                            val attempted = mutableSetOf<String>()
                            nativeAware.state.collect { state -> state.peers.forEach { peer ->
                                if (attempted.add(peer.id)) nativeAware.pair(peer.id, requireNotNull(args.getString("nearbyDevicePIN")))
                            } }
                        }
                    } else {
                        radio.onRoom = { if (it.roomID == room && radio.canConnect(room)) discovered.countDown() }
                        radio.setMode(BluetoothDiscoveryMode.BROWSING)
                    }
                }
                assertTrue("Bluetooth session endpoint not discovered", discovered.await(30, TimeUnit.SECONDS))
                lateinit var connect: () -> NearbyByteConnection
                instrumentation.runOnMainSync {
                    connect = aware?.connector(room) ?: run { radio.setJoinedRoom(room); radio.connector(room) }
                }
                bridge.startGuest(room, connect)
                credential = SessionCredential.derive(admission.join("127.0.0.1", room, "2468"), room)
                Log.i("NearbyPhysical", "BLE room admission authenticated")
            }
            audio.configureSession(room, participant, role!!, ParticipantPlatform.ANDROID, credential)
            control.configureSession(room, participant, role, ParticipantPlatform.ANDROID, credential)
            asset.configureSession(room, participant, role, ParticipantPlatform.ANDROID, credential)
            if (role == "guide") {
                val audioJoined = AtomicInteger()
                audio.setSessionEventHandler { if (it is AudioSessionEvent.Joined) audioJoined.incrementAndGet() }
                audio.startBroadcasting(room.toString(), AudioQuality.STANDARD)
                control.startGuide(); asset.startGuide()
                instrumentation.runOnMainSync {
                    val record = BluetoothRoomRecord(room, guideID, "Physical nearby fixture", true, true)
                    val nativeAware = aware
                    if (nativeAware != null) {
                        nativeAware.onError = { Log.w("NearbyPhysical", "Aware: $it") }
                        nativeAware.publish(record); nativeAware.setMode(BluetoothDiscoveryMode.ADVERTISING)
                    } else {
                        radio.publish(record); radio.setMode(BluetoothDiscoveryMode.ADVERTISING)
                    }
                }
                Log.i("NearbyPhysical", "BLE guide ready")
                repeat(3_000) { frame ->
                    val pcm = ByteBuffer.allocate(640).order(ByteOrder.LITTLE_ENDIAN)
                    repeat(320) { index -> pcm.putShort((sin((frame * 320L + index) * 440 * 2 * PI / 16_000) * 8_000).toInt().toShort()) }
                    audio.sendAudio(pcm.array())
                    if (frame % 50 == 0) {
                        control.send(SessionMessageKind.VISUAL_FOCUS_SNAPSHOT,
                            VisualFocusSnapshotPayload(frame.toLong(), TourVisualMode.POINTER).encode())
                        asset.send(SessionMessageKind.ASSET_CHUNK, chunk.encode(), null)
                    }
                    Thread.sleep(20)
                }
                assertTrue("No Bluetooth audio guest authenticated", audioJoined.get() >= 1)
            } else {
                val controlReceived = CountDownLatch(1)
                val assetReceived = CountDownLatch(1)
                val audioFrames = CountDownLatch(100)
                control.setEventHandler { event ->
                    Log.d("NearbyPhysical", "Control event ${event.javaClass.simpleName}")
                    if (event is SessionControlEvent.Failed) Log.w("NearbyPhysical", event.message)
                    if (event is SessionControlEvent.EnvelopeReceived && event.envelope.kind == SessionMessageKind.VISUAL_FOCUS_SNAPSHOT) {
                        assertEquals(TourVisualMode.POINTER, VisualFocusSnapshotPayload.decode(event.envelope.payload).mode)
                        controlReceived.countDown()
                    }
                }
                asset.setEventHandler { event ->
                    Log.d("NearbyPhysical", "Asset event ${event.javaClass.simpleName}")
                    if (event is SessionAssetEvent.Failed) Log.w("NearbyPhysical", event.message)
                    if (event is SessionAssetEvent.EnvelopeReceived && event.envelope.kind == SessionMessageKind.ASSET_CHUNK) {
                        val decoded = AssetChunkPayload.decode(event.envelope.payload)
                        assertEquals(assetHash, decoded.sha256); assertArrayEquals(assetBytes, decoded.bytes)
                        assetReceived.countDown()
                    }
                }
                control.hostIP = "127.0.0.1"; asset.hostIP = "127.0.0.1"; audio.hostIP = "127.0.0.1"
                control.startGuest(); asset.startGuest()
                audio.startListening(room.toString()) { pcm -> if (pcm.any { it != 0.toByte() }) audioFrames.countDown() }
                assertTrue("No authoritative pointer state over BLE", controlReceived.await(20, TimeUnit.SECONDS))
                assertTrue("No byte-exact asset chunk over BLE", assetReceived.await(20, TimeUnit.SECONDS))
                val heard = audioFrames.await(20, TimeUnit.SECONDS)
                assertTrue("Only ${100 - audioFrames.count} of 100 non-silent native-decoded BLE audio frames", heard)
                Log.i("NearbyPhysical", "PASS: BLE admission, pointer, asset bytes, 100 native decoded audio frames")
            }
        } finally {
            audio.clearSession(); control.clearSession(); asset.clearSession(); admission.stop()
            bridge.close()
            pairingScope.cancel()
            instrumentation.runOnMainSync { radio.stop(); aware?.stop() }
            activity.close()
        }
    }
}
