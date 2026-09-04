package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.service.AudioEngine
import org.junit.Assert.assertEquals
import org.junit.Test

class ListenerOutputTest {
    @Test
    fun privateAudioTogglesToSpeakerAndBack() {
        val output = ListenerOutput.PRIVATE_AUDIO

        assertEquals(ListenerOutput.SPEAKER, output.toggled())
        assertEquals(ListenerOutput.PRIVATE_AUDIO, output.toggled().toggled())
    }

    @Test
    fun audioEngineDefaultsToPrivateAudio() {
        // FND-12: read the engine's own default, not a literal the test happens to agree with.
        assertEquals(ListenerOutput.PRIVATE_AUDIO, AudioEngine.DEFAULT_LISTENER_OUTPUT)
        assertEquals(ListenerOutput.SPEAKER, AudioEngine.DEFAULT_LISTENER_OUTPUT.toggled())
    }
}
