package com.aessam.comeoverhere

import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.service.NativeAudioCodecCapabilities
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeAudioCodecCapabilitiesTest {
    @Test
    fun reportsInstalledNativeCodecs() {
        val capabilities = NativeAudioCodecCapabilities.current()

        Log.i(
            "GOHCodecProbe",
            "sdk=${capabilities.sdkInt} " +
                "opusEncoder=${capabilities.opusEncoder ?: "none"} " +
                "opusDecoder=${capabilities.opusDecoder ?: "none"} " +
                "aacLCEncoder=${capabilities.aacLCEncoder ?: "none"} " +
                "aacLCDecoder=${capabilities.aacLCDecoder ?: "none"}",
        )

        assertNotNull("AAC-LC encoder is required on every supported Android version", capabilities.aacLCEncoder)
        assertNotNull("AAC-LC decoder is required on every supported Android version", capabilities.aacLCDecoder)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            assertNotNull("Android 10+ requires an Opus encoder on handhelds/tablets", capabilities.opusEncoder)
        }
        assertNotNull("Every supported Android version requires an Opus decoder", capabilities.opusDecoder)
    }
}
