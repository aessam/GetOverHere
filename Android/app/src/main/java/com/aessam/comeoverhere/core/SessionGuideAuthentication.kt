package com.aessam.comeoverhere.core

import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.SealedSessionEnvelope
import java.nio.ByteBuffer

class GuideAuthenticationException(cause: IllegalArgumentException) : IllegalArgumentException(
    "Guide authentication failed. Leave this room before joining again.", cause,
)

/** Session-scoped guide authority. Legacy is an explicit component-fixture profile, never an app fallback. */
sealed interface SessionGuideAuthentication {
    data object Unconfigured : SessionGuideAuthentication
    data object LegacyFixture : SessionGuideAuthentication
    class Guide(val signer: GuideFrameSigner) : SessionGuideAuthentication
    class Guest(val verifier: GuideFrameVerifier) : SessionGuideAuthentication

    fun requireGuide() {
        check(this is Guide || this == LegacyFixture) { "Guide signing identity is not configured" }
    }

    fun requireGuest() {
        check(this is Guest || this == LegacyFixture) { "Admitted guide identity is not configured" }
    }

    fun encodeGuide(frame: SealedSessionEnvelope): ByteArray = when (this) {
        is Guide -> signer.sign(frame).encode()
        LegacyFixture -> frame.encode()
        else -> error("Guide signing identity is not configured")
    }

    /** Signature verification precedes AEAD and never accepts a key supplied by the frame. */
    fun decodeGuide(frame: ByteArray): SealedSessionEnvelope = when (this) {
        is Guest -> try { verifier.verify(frame) } catch (error: IllegalArgumentException) {
            throw GuideAuthenticationException(error)
        }
        LegacyFixture -> SealedSessionEnvelope.decode(frame)
        else -> error("Admitted guide identity is not configured")
    }
}

/** Scheduling classification only. Receiving transports authenticate before consuming the inner frame. */
internal fun isNearbyAudioFrame(frame: ByteArray): Boolean {
    val offset = if (frame.size >= 4 && frame.copyOfRange(0, 4).contentEquals(byteArrayOf(71, 79, 83, 49))) {
        require(frame.size in 158..65_608 && ByteBuffer.wrap(frame, 4, 4).int == frame.size - 72) {
            "Invalid signed guide frame length"
        }
        8
    } else 0
    require(frame.size >= offset + 86 && frame.copyOfRange(offset, offset + 4).contentEquals(byteArrayOf(71, 79, 72, 50))) {
        "Invalid nearby session frame"
    }
    require(frame[offset + 4] == 4.toByte()) { "Unsupported nearby session version" }
    return frame[offset + 7].toInt() == 0x10
}
