package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BluetoothRoomRecordTest {
    /** Mirrors BluetoothRoomRecordTests.packAdvert (ADR-080). */
    @Test fun packAdvert() {
        val room = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val guide = UUID.fromString("ffeeddcc-bbaa-9988-7766-554433221100")
        val pack = TourPackAdvert(UUID.fromString("6f1c5c6a-0000-4000-8000-0000000000a1"), 0x0102030405060708L)
        val record = BluetoothRoomRecord(room, guide, "Tour", false, true, 2, pack)
        assertEquals("474f52320600112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f75726f1c5c6a0000400080000000000000a10102030405060708", record.encode().lowercaseHex())
        assertEquals(record, BluetoothRoomRecord.decode(record.encode()))
        // 39 + 376 + 24 = 439: the longest name that still fits with an advert.
        val longest = BluetoothRoomRecord(room, guide, "x".repeat(376), true, false, pack = pack)
        assertEquals(longest, BluetoothRoomRecord.decode(longest.encode()))
        assertThrows(IllegalArgumentException::class.java) {
            BluetoothRoomRecord(room, guide, "x".repeat(377), true, false, pack = pack).encode()
        }
        val bytes = record.encode()
        for (count in 0 until bytes.size) {
            assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(bytes.copyOfRange(0, count)) }
        }
        val noAdvert = bytes.copyOf().also { it[4] = (it[4].toInt() and 4.inv()).toByte() }
        assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(noAdvert) }
    }

    @Test fun sharedFixtureAndRoundtrips() {
        val room = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val guide = UUID.fromString("ffeeddcc-bbaa-9988-7766-554433221100")
        val fixture = BluetoothRoomRecord(room, guide, "Tour", true, true)
        assertEquals("474f52310300112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f7572",
            fixture.encode().joinToString("") { "%02x".format(it) })
        val v2 = fixture.copy(admissionVersion = 2)
        assertEquals("474f52320300112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f7572",
            v2.encode().lowercaseHex())
        assertEquals(v2, BluetoothRoomRecord.decode(v2.encode()))
        for (index in 1..100) {
            val value = BluetoothRoomRecord(room, guide, "ج🌍".repeat(index % 50 + 1), index % 2 == 0, index % 3 == 0,
                admissionVersion = index % 2 + 1)
            assertEquals(value, BluetoothRoomRecord.decode(value.encode()))
        }
        val maximum = BluetoothRoomRecord(room, guide, "x".repeat(400), false, false)
        assertEquals(maximum, BluetoothRoomRecord.decode(maximum.encode()))
    }
    @Test fun malformedRecordsFailClosed() {
        assertThrows(Exception::class.java) {
            BluetoothRoomRecord(UUID.randomUUID(), UUID.randomUUID(), "\uD800", false, false).encode()
        }
        val bytes = BluetoothRoomRecord(UUID.randomUUID(), UUID.randomUUID(), "Tour", false, false).encode()
        for (count in bytes.indices) assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(bytes.copyOf(count)) }
        assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(bytes.copyOf().also { it[4] = 4 }) }
        assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(bytes.copyOf().also { it[39] = 255.toByte() }) }
        assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(bytes + byteArrayOf(0)) }
        listOf(0, 3, 255).forEach { version ->
            assertThrows(Exception::class.java) {
                BluetoothRoomRecord(UUID.randomUUID(), UUID.randomUUID(), "Tour", false, false, version).encode()
            }
            assertThrows(Exception::class.java) { BluetoothRoomRecord.decode(bytes.copyOf().also { it[3] = version.toByte() }) }
        }
    }
}
