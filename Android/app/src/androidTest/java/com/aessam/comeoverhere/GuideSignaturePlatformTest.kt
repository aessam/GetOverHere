package com.aessam.comeoverhere

import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.TourSessionFixtures
import com.aessam.toursession.hexToByteArray
import com.aessam.toursession.lowercaseHex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GuideSignaturePlatformTest {
    @Test fun nativeProviderSignsAndVerifiesProductionFrames() {
        val frame = TourSessionFixtures.encryptedRealtimeFixture()
        repeat(100) {
            val signer = GuideFrameSigner(frame.sessionId, frame.senderId)
            val signed = signer.sign(frame).encode()
            val verifier = GuideFrameVerifier(signer.publicKey, frame.sessionId, frame.senderId)
            assertArrayEquals(frame.encode(), verifier.verify(signed).encode())
            signed[signed.lastIndex] = (signed.last().toInt() xor 1).toByte()
            assertThrows(Exception::class.java) { verifier.verify(signed) }
        }
        val arguments = InstrumentationRegistry.getArguments()
        val key = arguments.getString("guideKey")
        val packet = arguments.getString("guidePacket")
        require((key == null) == (packet == null)) { "Both cross-platform signature arguments are required" }
        if (key != null && packet != null) {
            val verifier = GuideFrameVerifier(key.hexToByteArray(), frame.sessionId, frame.senderId)
            assertArrayEquals(frame.encode(), verifier.verify(packet.hexToByteArray()).encode())
        }
        val signer = GuideFrameSigner(frame.sessionId, frame.senderId)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
            // Public fixture key/signature only. Never export the private key.
            putString("guide_signature", signer.publicKey.lowercaseHex() + "|" + signer.sign(frame).encode().lowercaseHex())
        })
    }
}
