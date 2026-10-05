package com.aessam.comeoverhere

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.service.AudioEngine
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * FND-13 on a device or emulator: ACTION_AUDIO_BECOMING_NOISY forces private output and a lost
 * audio focus reaches the product callback. Separate from AudioEngineRoutingTest (G6 edits that file).
 * The earpiece assertion is skipped where the platform exposes no earpiece (emulators, DSCN-14).
 */
@RunWith(AndroidJUnit4::class)
class AudioEngineFocusTest {
    private lateinit var audioEngine: AudioEngine
    private lateinit var audioManager: AudioManager
    private lateinit var activity: ActivityScenario<MainActivity>

    @Before
    fun setUp() {
        activity = ActivityScenario.launch(MainActivity::class.java)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        audioEngine = AudioEngine(context)
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    @After
    fun tearDown() {
        audioEngine.stopPlayback()
        activity.close()
    }

    @Test
    fun audioBecomingNoisyForcesPrivateOutput() {
        val forced = CountDownLatch(1)
        audioEngine.onOutputForcedPrivate = { forced.countDown() }
        audioEngine.startPlayback()
        audioEngine.setListenerOutput(ListenerOutput.SPEAKER)
        assertEquals(ListenerOutput.SPEAKER, audioEngine.appliedListenerOutput)

        audioEngine.handleAudioBecomingNoisy()

        assertTrue("forced-private callback did not fire", forced.await(2, TimeUnit.SECONDS))
        assertEquals(ListenerOutput.PRIVATE_AUDIO, audioEngine.appliedListenerOutput)
    }

    /** Physical-device half (DSCN-14): emulators expose no built-in earpiece, so this is skipped there. */
    @Test
    fun audioBecomingNoisyRoutesToEarpiece() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        val hasEarpiece = audioManager.availableCommunicationDevices.any {
            it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
        }
        assumeTrue("no built-in earpiece on this device; route assertion needs hardware", hasEarpiece)

        audioEngine.startPlayback()
        audioEngine.setListenerOutput(ListenerOutput.SPEAKER)
        audioEngine.handleAudioBecomingNoisy()

        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, audioManager.communicationDevice?.type)
    }

    @Test
    fun losingAudioFocusInvokesCallback() {
        val lost = CountDownLatch(1)
        audioEngine.onAudioFocusLost = { lost.countDown() }
        audioEngine.startPlayback()

        val competing = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setOnAudioFocusChangeListener { }
            .build()
        try {
            assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, audioManager.requestAudioFocus(competing))
            assertTrue("engine did not observe the focus loss", lost.await(2, TimeUnit.SECONDS))
        } finally {
            audioManager.abandonAudioFocusRequest(competing)
        }
    }
}
