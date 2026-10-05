package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class RoomAdmissionTest {
    @Test fun leadingZeroSharedSecretKeepsFixedWidthThroughHKDF() {
        val parameters = java.security.AlgorithmParameters.getInstance("EC").apply {
            init(java.security.spec.ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(java.security.spec.ECParameterSpec::class.java)
        val factory = java.security.KeyFactory.getInstance("EC")
        val key = java.security.KeyPair(
            factory.generatePublic(java.security.spec.ECPublicKeySpec(parameters.generator, parameters)),
            factory.generatePrivate(java.security.spec.ECPrivateKeySpec(java.math.BigInteger.ONE, parameters)),
        )
        // Private scalars 1 and 379; identical CryptoKit fixture. Never a random coverage claim.
        val peer = "04005543894af3d00ed7d740abdbd75c96b06877b787db5f70eea78b90a8d7c00abb4c85a3d8ea29efaafa24406912dd84d5b14dc32bf656ef6c6bd58a5d943f92".hexToByteArray()
        val result = RoomAdmission.derive(key, peer, ByteArray(32), byteArrayOf())
        assertEquals("1652d7207df35c849397c233a68b03323308bd4dcd2f50e20ab8323fea0bd015",
            result.joinToString("") { "%02x".format(it.toInt() and 255) })
        val v2 = RoomAdmission.derive(key, peer, ByteArray(32), byteArrayOf(), "GetOverHere/room-admission/v2")
        assertEquals("e6c7820134e8240ee5ab4f70d589cc9a4e29531739e7301a50e24057f06a53fd", v2.lowercaseHex())
    }

    @Test fun roundtripAndTamper() {
        listOf(null, "1234", "My-Tour!42", "a".repeat(64)).forEach { code ->
            val id = UUID.randomUUID()
            val guide = RoomAdmission.Guide(id, RoomAccessPolicy(id, code))
            val guest = RoomAdmission.Guest(guide.challenge, id, code)
            val reply = guide.reply(guest.request, "23456789AB")
            assertEquals("23456789AB", guest.open(reply))
            reply[20] = (reply[20].toInt() xor 1).toByte()
            assertThrows(Exception::class.java) { guest.open(reply) }
        }
    }

    @Test fun rejectsWrongCodeAndReplay() {
        val id = UUID.randomUUID()
        val policy = RoomAccessPolicy(id, "1234")
        val guide = RoomAdmission.Guide(id, policy)
        assertThrows(Exception::class.java) { RoomAdmission.Guest(guide.challenge, id, null) }
        val wrong = RoomAdmission.Guest(guide.challenge, id, "5678")
        assertThrows(Exception::class.java) { guide.reply(wrong.request, "23456789AB") }
        val guest = RoomAdmission.Guest(guide.challenge, id, "1234")
        assertThrows(Exception::class.java) { RoomAdmission.Guide(id, policy).reply(guest.request, "23456789AB") }
        assertThrows(Exception::class.java) { RoomAdmission.Guest(guide.challenge, UUID.randomUUID(), "1234") }
    }

    @Test fun invalidCodes() {
        listOf("", "123", "ab cd", "é123", "x".repeat(65)).forEach { assertFalse(RoomAccessPolicy.isValidCode(it)) }
    }
}
