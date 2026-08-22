package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.ListenerOutput
import org.junit.Assert.assertEquals
import org.junit.Test

class ListenerOutputTest {
    @Test
    fun privateAudioTogglesToSpeakerAndBack() {
        val output = ListenerOutput.PRIVATE_AUDIO

        assertEquals(ListenerOutput.SPEAKER, output.toggled())
        assertEquals(ListenerOutput.PRIVATE_AUDIO, output.toggled().toggled())
    }
}
