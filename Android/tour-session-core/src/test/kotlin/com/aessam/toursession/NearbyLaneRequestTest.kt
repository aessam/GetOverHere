package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NearbyLaneRequestTest {
    @Test fun sharedFixtureAndEveryLaneRoundtrip() {
        val request = NearbyLaneRequest(NearbyLaneRequest.Lane.ADMISSION,
            UUID.fromString("00112233-4455-6677-8899-aabbccddeeff"))
        assertEquals("474f44310400112233445566778899aabbccddeeff", request.encode().joinToString("") { "%02x".format(it) })
        NearbyLaneRequest.Lane.entries.forEach { lane ->
            repeat(100) {
                val value = NearbyLaneRequest(lane, if (lane == NearbyLaneRequest.Lane.METADATA)
                    NearbyLaneRequest.METADATA_ROOM_ID else UUID.randomUUID())
                assertEquals(value, NearbyLaneRequest.decode(value.encode()))
            }
        }
        assertEquals((50_000..50_003).toSet(), NearbyLaneRequest.Lane.entries.mapNotNull { it.localPort }.toSet())
        assertEquals(50_004, NearbyLaneRequest.SERVICE_PORT)
    }

    @Test fun rejectsMalformedAndUnscopedApplicationRequests() {
        val good = NearbyLaneRequest(NearbyLaneRequest.Lane.CONTROL, UUID.randomUUID()).encode()
        for (length in good.indices) rejects { NearbyLaneRequest.decode(good.copyOf(length)) }
        rejects { NearbyLaneRequest.decode(good + byteArrayOf(0)) }
        rejects { NearbyLaneRequest.decode(good.copyOf().apply { this[4] = 255.toByte() }) }
        rejects { NearbyLaneRequest.decode(good.copyOf().apply { this[3] = 50 }) }
        rejects { NearbyLaneRequest(NearbyLaneRequest.Lane.ADMISSION, NearbyLaneRequest.METADATA_ROOM_ID) }
        rejects { NearbyLaneRequest(NearbyLaneRequest.Lane.METADATA, UUID.randomUUID()) }
    }

    private fun rejects(body: () -> Unit) { assertThrows(IllegalArgumentException::class.java, body) }
}
