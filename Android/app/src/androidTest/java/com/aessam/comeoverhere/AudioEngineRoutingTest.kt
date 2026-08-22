package com.aessam.comeoverhere

import android.Manifest
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.service.AudioEngine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AudioEngineRoutingTest {
    private lateinit var audioEngine: AudioEngine
    private lateinit var audioManager: AudioManager

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        audioEngine = AudioEngine(context)
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    @After
    fun tearDown() {
        audioEngine.stopPlayback()
    }

    @Test
    fun listenerOutputSwitchesPhysicalCommunicationDevice() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)

        audioEngine.setListenerOutput(ListenerOutput.PRIVATE_AUDIO)
        audioEngine.startPlayback()
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, audioManager.communicationDevice?.type)

        audioEngine.setListenerOutput(ListenerOutput.SPEAKER)
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, audioManager.communicationDevice?.type)
    }

    @Test
    fun voiceCommunicationCaptureProducesAFrame() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(
            instrumentation.targetContext.packageName,
            Manifest.permission.RECORD_AUDIO,
        )

        val frame = withTimeout(5_000) {
            audioEngine.startCapture().first()
        }

        assertEquals(0, frame.size % Float.SIZE_BYTES)
        assertTrue(frame.isNotEmpty())
    }
}
