package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.RoomAdmissionTransport
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.hexToByteArray
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.util.UUID
import javax.crypto.KeyAgreement
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** Exercise Android's actual JCA and NIO providers, not just the host JVM implementations. */
class RoomAdmissionBoundaryTest {
    @Test fun androidECDHProviderPreservesLeadingZero() {
        val parameters = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        val factory = KeyFactory.getInstance("EC")
        val privateKey = factory.generatePrivate(ECPrivateKeySpec(BigInteger.ONE, parameters))
        val peer = "04005543894af3d00ed7d740abdbd75c96b06877b787db5f70eea78b90a8d7c00abb4c85a3d8ea29efaafa24406912dd84d5b14dc32bf656ef6c6bd58a5d943f92".hexToByteArray()
        val point = ECPoint(BigInteger(1, peer.copyOfRange(1, 33)), BigInteger(1, peer.copyOfRange(33, 65)))
        val publicKey = factory.generatePublic(ECPublicKeySpec(point, parameters))
        val shared = KeyAgreement.getInstance("ECDH").apply { init(privateKey); doPhase(publicKey, true) }.generateSecret()
        assertEquals(32, shared.size)
        assertArrayEquals(peer.copyOfRange(1, 33), shared)
    }

    @Test fun androidNonblockingReplyPreservesLockEditUnlock() {
        val id = UUID.randomUUID()
        val transport = RoomAdmissionTransport(56003)
        try {
            transport.start(id, "23456789AB")
            assertEquals("23456789AB", transport.join("127.0.0.1", id, null))
            transport.update(RoomAccessPolicy(id, "1234"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, "wrong") }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, "1234"))
            transport.update(RoomAccessPolicy(id, "Edited!"))
            assertThrows(Exception::class.java) { transport.join("127.0.0.1", id, "1234") }
            assertEquals("23456789AB", transport.join("127.0.0.1", id, "Edited!"))
            transport.update(RoomAccessPolicy(id, null))
            assertEquals("23456789AB", transport.join("127.0.0.1", id, null))
        } finally { transport.stop() }
    }
}
