package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BluetoothRoomRecordTest {
    @Test fun sharedFixtureAndRoundtrips() {
        val room = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val guide = UUID.fromString("ffeeddcc-bbaa-9988-7766-554433221100")
        val fixture = BluetoothRoomRecord(room, guide, "Tour", true, true)
        assertEquals("474f52310300112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000004546f7572",
            fixture.encode().joinToString("") { "%02x".format(it) })
        for (index in 1..100) {
            val value = BluetoothRoomRecord(room, guide, "ج🌍".repeat(index % 50 + 1), index % 2 == 0, index % 3 == 0)
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
    }
}
