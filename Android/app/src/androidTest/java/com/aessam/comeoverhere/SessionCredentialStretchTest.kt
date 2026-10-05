package com.aessam.comeoverhere

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.TourSessionFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Measures one on-device PBKDF2 stretch (DSCN-8) and proves the device provider produces the same
 * proofs as SunJCE and CommonCrypto. The 5 s bound is a sanity ceiling only; the iteration-count
 * decision threshold is read from the logged value, never asserted here.
 */
@RunWith(AndroidJUnit4::class)
class SessionCredentialStretchTest {
    @Test
    fun stretchedCredentialDerivesWithinSanityCeilingAndMatchesJvm() {
        val started = System.nanoTime()
        val hex = TourSessionFixtures.authenticationFixtureHex()
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        Log.i(TAG, "PBKDF2 derive (emulator): $elapsedMs ms")
        assertEquals(4, SealedSessionEnvelope.MAJOR_VERSION)
        assertEquals(
            "5f837f1767e9bddd9a65096b1b2f458f1329a4f1c9e9a4d09bb9f15f8225a86d|98950abd4bf6d1e9ef3ea546586c7d027797d5e379aab69f1b99c23067d90a8f",
            hex,
        )
        assertTrue("derive took $elapsedMs ms", elapsedMs < 5_000)
    }

    private companion object {
        const val TAG = "SessionCredentialStretchTest"
    }
}
