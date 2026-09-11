package com.aessam.comeoverhere

import android.Manifest
import android.app.KeyguardManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.aessam.comeoverhere.core.BluetoothRoomDiscovery
import com.aessam.comeoverhere.service.AudioRuntimeState
import com.aessam.comeoverhere.service.ChannelService
import com.aessam.comeoverhere.service.ListenState
import com.aessam.comeoverhere.service.SessionConnectionState
import com.aessam.toursession.SessionTransportRoute
import com.aessam.toursession.TourVisualMode
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit real capture → production session → native Bluetooth → real playback gate.
 * No generated audio, mock service, LAN fallback or device radio changes.
 * Renderer/readiness assertions are not an acoustic quality measurement.
 */
@RunWith(AndroidJUnit4::class)
class NearbyLiveSessionTest {
    @get:Rule val permissions: GrantPermissionRule = GrantPermissionRule.grant(*(
        listOf(Manifest.permission.RECORD_AUDIO) + BluetoothRoomDiscovery.requiredPermissions().toList() +
            if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.NEARBY_WIFI_DEVICES) else emptyList()
        ).toTypedArray())

    @Test fun productionSessionDeliversLiveAudioAndReadinessOverBluetooth() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val role = arguments.getString("nearbyRole")
        assumeTrue("Requires an explicit physical cross-platform pair", role == "guide" || role == "guest")
        assumeTrue("Native BLE sockets require Android10+", Build.VERSION.SDK_INT >= 29)
        assumeTrue("Physical microphone/radio required", !Build.FINGERPRINT.contains("generic"))
        val name = requireNotNull(arguments.getString("nearbyRoomName"))
        val app = instrumentation.targetContext.applicationContext as ComeOverHereApp
        val service = app.channelService
        val activity = ActivityScenario.launch(MainActivity::class.java)
        var previousBluetooth = false
        var previousAware = false
        var ownsSessionSetup = false
        try {
            prepareForeground(activity)
            activity.onActivity {
                check(service.activeChannelID.value == null) { "End the current tour before physical testing" }
                previousBluetooth = service.bluetoothDiscoveryEnabled.value
                previousAware = service.awareSettings?.state?.value?.enabled == true
                ownsSessionSetup = true
                service.setBluetoothDiscoveryEnabled(true)
                service.awareSettings?.setEnabled(false)
            }
            if (role == "guide") {
                instrumentation.runOnMainSync { service.createChannel(name) }
                await("guide microphone startup", 15, service) {
                    service.listenState.value == ListenState.BROADCASTING &&
                        service.audioRuntimeState.value == AudioRuntimeState.RUNNING
                }
                assertFalse(service.isRoomLocked.value)
                await("guest audio-ready report", 90, service) { service.audioReadyGuestCount.value == 1 }
                instrumentation.runOnMainSync { service.setVisualFocus(TourVisualMode.POINTER) }
                SystemClock.sleep(10_000)
                assertEquals(AudioRuntimeState.RUNNING, service.audioRuntimeState.value)
            } else {
                await("joinable Bluetooth room", 90, service) {
                    service.channels.value.any { it.name == name && service.canJoin(it.copy(audioHostIP = null)) }
                }
                instrumentation.runOnMainSync {
                    val selected = service.channels.value.first { it.name == name }.copy(audioHostIP = null)
                    service.joinChannel(selected, "")
                }
                await("authenticated live playback", 45, service) {
                    service.connectionState.value == SessionConnectionState.CONNECTED &&
                        service.audioRuntimeState.value == AudioRuntimeState.RUNNING
                }
                instrumentation.runOnMainSync {
                    assertEquals(SessionTransportRoute.BLUETOOTH, service.resolvedGuestRoute?.transport)
                    assertEquals(UUID.fromString(service.activeChannelID.value), service.resolvedGuestRoute?.roomID)
                }
                await("authoritative pointer state", 15, service) {
                    service.visualFocusSnapshot.value?.mode == TourVisualMode.POINTER
                }
                var acceptedBytes = app.audioEngine.acceptedPlaybackByteCount
                val initialAcceptedBytes = acceptedBytes
                val cadenceStarted = SystemClock.elapsedRealtime()
                repeat(5) {
                    SystemClock.sleep(1_000)
                    assertEquals(AudioRuntimeState.RUNNING, service.audioRuntimeState.value)
                    assertEquals(SessionConnectionState.CONNECTED, service.connectionState.value)
                    instrumentation.runOnMainSync {
                        assertEquals(SessionTransportRoute.BLUETOOTH, service.resolvedGuestRoute?.transport)
                    }
                    val updatedBytes = app.audioEngine.acceptedPlaybackByteCount
                    assertTrue("No new PCM accepted by renderer for one second", updatedBytes > acceptedBytes)
                    acceptedBytes = updatedBytes
                }
                val deliveredBytes = acceptedBytes - initialAcceptedBytes
                val elapsedMilliseconds = SystemClock.elapsedRealtime() - cadenceStarted
                Log.i("NearbyLive", "Live BLE cadence: acceptedPCMBytes=$deliveredBytes, " +
                    "elapsedMs=$elapsedMilliseconds, minimumPCMBytes=128000")
                // 16 kHz mono PCM16 is 32,000 bytes/s: require 80% of five nominal seconds.
                // This is a cadence smoke test, not an acoustic or latency acceptance test.
                assertTrue("Live PCM cadence below the five-second smoke threshold", deliveredBytes >= 128_000L)
            }
        } finally {
            try {
                if (ownsSessionSetup) instrumentation.runOnMainSync {
                    service.leaveChannel()
                    service.setBluetoothDiscoveryEnabled(previousBluetooth)
                    service.awareSettings?.setEnabled(previousAware)
                }
            } finally {
                activity.close()
            }
        }
    }

    private fun prepareForeground(scenario: ActivityScenario<MainActivity>) {
        var dismissalError: String? = null
        scenario.onActivity { activity ->
            val keyguard = activity.getSystemService(KeyguardManager::class.java)
            check(!keyguard.isDeviceLocked) { "Unlock the Android phone before the foreground live test" }
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            activity.setTurnScreenOn(true)
            // A swipe-only lock screen can stop an Activity even though no credential is needed.
            // Use the public dismissal flow, never override the service's foreground policy.
            activity.setShowWhenLocked(true)
            if (keyguard.isKeyguardLocked) {
                keyguard.requestDismissKeyguard(activity, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissError() { dismissalError = "Keyguard dismissal failed" }
                    override fun onDismissCancelled() { dismissalError = "Keyguard dismissal cancelled" }
                })
            }
        }
        val deadline = SystemClock.elapsedRealtime() + 10_000
        var detail = "Foreground preflight did not run"
        while (true) {
            var ready = false
            scenario.onActivity { activity ->
                val keyguard = activity.getSystemService(KeyguardManager::class.java)
                val power = activity.getSystemService(PowerManager::class.java)
                val state = activity.lifecycle.currentState
                val focused = activity.hasWindowFocus()
                detail = "state=$state, focused=$focused, interactive=${power.isInteractive}, " +
                    "keyguard=${keyguard.isKeyguardLocked}, deviceLocked=${keyguard.isDeviceLocked}"
                check(dismissalError == null) { "$dismissalError; $detail" }
                ready = state == Lifecycle.State.RESUMED && focused && power.isInteractive &&
                    !keyguard.isKeyguardLocked && !keyguard.isDeviceLocked
            }
            if (ready) {
                scenario.onActivity { it.setShowWhenLocked(false) }
                Log.i("NearbyLive", "Foreground preflight passed: $detail")
                return
            }
            check(SystemClock.elapsedRealtime() < deadline) { "Android app is not foreground: $detail" }
            SystemClock.sleep(100)
        }
    }

    private fun await(stage: String, seconds: Int, service: ChannelService, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + seconds * 1_000L
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        while (true) {
            var ready = false
            instrumentation.runOnMainSync { ready = condition() }
            if (ready) return
            assertTrue("$stage: ${service.audioRuntimeError.value ?: service.tourFeatureError.value}",
                service.connectionState.value != SessionConnectionState.FAILED &&
                    service.audioRuntimeState.value != AudioRuntimeState.FAILED)
            assertTrue("Timed out: $stage; ${service.tourFeatureError.value}",
                SystemClock.elapsedRealtime() < deadline)
            SystemClock.sleep(100)
        }
    }
}
