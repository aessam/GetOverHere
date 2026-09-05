package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class RoomAdmissionTest {
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
