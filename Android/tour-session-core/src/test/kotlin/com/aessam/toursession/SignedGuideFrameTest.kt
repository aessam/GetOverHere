package com.aessam.toursession

import java.util.Random
import java.math.BigInteger
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SignedGuideFrameTest {
    @Test fun exactCiphertextSurvivesAndEverySingleByteChangeFails() {
        val sealed = TourSessionFixtures.encryptedRealtimeFixture()
        val signer = GuideFrameSigner(sealed.sessionId, sealed.senderId)
        val verifier = GuideFrameVerifier(signer.publicKey, sealed.sessionId, sealed.senderId)
        val signed = signer.sign(sealed)
        val bytes = signed.encode()
        assertArrayEquals(sealed.encode(), verifier.verify(bytes).encode())
        val high = (GuideSignatureEncoding.order - BigInteger(1, bytes.takeLast(32).toByteArray())).toByteArray().takeLast(32).toByteArray()
        assertThrows(Exception::class.java) { verifier.verify(bytes.copyOfRange(0, bytes.size - 32) + high) }
        bytes.indices.forEach { index ->
            val changed = bytes.copyOf(); changed[index] = (changed[index].toInt() xor 1).toByte()
            assertThrows(Exception::class.java) { verifier.verify(changed) }
        }
        (0 until bytes.size).forEach { count -> assertThrows(Exception::class.java) { verifier.verify(bytes.copyOf(count)) } }
        assertThrows(Exception::class.java) { verifier.verify(bytes + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { verifier.verify(sealed.encode()) }
        bytes[0] = 0
        assertArrayEquals(sealed.encode(), verifier.verify(signed.encode()).encode())
    }

    @Test fun wrongKeyGuideAndSessionAreRejected() {
        val sealed = TourSessionFixtures.encryptedRealtimeFixture()
        val signer = GuideFrameSigner(sealed.sessionId, sealed.senderId)
        val bytes = signer.sign(sealed).encode()
        val other = GuideFrameSigner(sealed.sessionId, sealed.senderId)
        listOf(GuideFrameVerifier(other.publicKey, sealed.sessionId, sealed.senderId),
            GuideFrameVerifier(signer.publicKey, UUID.randomUUID(), sealed.senderId),
            GuideFrameVerifier(signer.publicKey, sealed.sessionId, UUID.randomUUID())).forEach {
            assertThrows(Exception::class.java) { it.verify(bytes) }
        }
        assertThrows(Exception::class.java) { GuideFrameSigner(sealed.sessionId, UUID.randomUUID()).sign(sealed) }
    }

    @Test fun rawDERConversionPreservesLeadingZerosAndHighBits() {
        val random = Random(38)
        val samples = listOf(ByteArray(64), ByteArray(64) { 0x80.toByte() }, ByteArray(64) { 0xff.toByte() }) +
            List(1000) { ByteArray(64).also { random.nextBytes(it); it[0] = 0; it[32] = 0 } }
        samples.forEach { assertArrayEquals(it, GuideSignatureEncoding.raw(GuideSignatureEncoding.der(it))) }
        assertThrows(Exception::class.java) { GuideSignatureEncoding.raw(byteArrayOf(0x30, 6, 2, 1, 0x80.toByte(), 2, 1, 1)) }
    }
}
