package com.aessam.comeoverhere

import android.util.Log
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.LocalControlPlane
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.LocalSessionControlTransport
import com.aessam.comeoverhere.core.UDPAudioPlane
import com.aessam.comeoverhere.service.SessionConnectionState
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.SessionCredential
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/**
 * ChannelService-level proof of FND-1 on Android (DSCN-9): the application's real ChannelService
 * joins an in-process guide, the guide closes only the realtime lane, and the guest schedules a
 * reconnect. `ChannelService.channels` is filled only by NSD discovery, so the in-process guide
 * publishes its channel through a second `LocalControlPlane`; a JVM test cannot do this because
 * `LocalControlPlane` needs `NsdManager`.
 */
@RunWith(AndroidJUnit4::class)
class AudioLaneReconnectTest {
    @Test
    fun audioLaneLossSchedulesReconnect() {
        ActivityScenario.launch(MainActivity::class.java).use {
            runBlocking { runScenario() }
        }
    }

    private suspend fun runScenario() {
        val app = ApplicationProvider.getApplicationContext<ComeOverHereApp>()
        val service = app.channelService
        val sessionID = UUID.randomUUID()
        val guideID = UUID.randomUUID()
        val credential = SessionCredential.derive(TOUR_CODE, sessionID)
        val guideControl = LocalSessionControlTransport()
        val guideAssets = LocalSessionAssetTransport()
        val guideAudio = UDPAudioPlane()
        val guideDiscovery = LocalControlPlane(app, "Guide")
        val admission = com.aessam.comeoverhere.core.RoomAdmissionTransport()
        val signer = com.aessam.toursession.GuideFrameSigner(sessionID, guideID)
        val authentication = com.aessam.comeoverhere.core.SessionGuideAuthentication.Guide(signer)
        try {
            admission.start(sessionID, TOUR_CODE, signer)
            guideControl.configureGuideAuthentication(authentication)
            guideControl.configureSession(sessionID, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            guideAssets.configureGuideAuthentication(authentication)
            guideAssets.configureSession(sessionID, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            guideAudio.configureGuideAuthentication(authentication)
            guideAudio.configureSession(sessionID, guideID, "Guide", ParticipantPlatform.ANDROID, credential)
            guideControl.startGuide()
            guideAssets.startGuide()
            guideAudio.startBroadcasting(sessionID.toString(), AudioQuality.STANDARD)
            guideDiscovery.broadcast(
                BLECommand.ChannelAnnounce(
                    channelID = sessionID.toString(),
                    channelName = "Tour",
                    createdBy = guideID.toString(),
                    audioQuality = AudioQuality.STANDARD,
                    wifiSSID = null,
                    audioHostIP = null,
                    roomAdmissionVersion = 2,
                    isRoomLocked = false,
                ),
            )

            val channel = withTimeout(15_000) {
                service.channels.first { list -> list.any { it.id == sessionID.toString() } }
                    .first { it.id == sessionID.toString() }
            }
            Log.i(TAG, "Discovered in-process guide channel; hostIP present=${channel.audioHostIP != null}")

            withContext(Dispatchers.Main) { service.joinChannel(channel, "") }
            withTimeout(10_000) { service.connectionState.first { it == SessionConnectionState.CONNECTED } }
            withTimeout(5_000) {
                while (guideAudio.acceptedClientSockets().isEmpty()) delay(50)
            }
            Log.i(TAG, "Guest connected on control and audio lanes; closing only the audio lane")

            guideAudio.stop()

            val state = withTimeout(3_000) {
                service.connectionState.first { it == SessionConnectionState.RECONNECTING }
            }
            assertEquals(SessionConnectionState.RECONNECTING, state)
            Log.i(TAG, "Guest scheduled reconnect after audio-lane loss: reconnectAttempt=${service.reconnectAttempt.value}")
        } finally {
            withContext(Dispatchers.Main) { service.leaveChannel() }
            guideAudio.clearSession()
            guideControl.clearSession()
            guideAssets.clearSession()
            guideDiscovery.stop()
            admission.stop()
        }
    }

    private companion object {
        const val TAG = "AudioLaneReconnectTest"
        const val TOUR_CODE = "23456789AB"
    }
}
