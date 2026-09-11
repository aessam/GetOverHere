package com.aessam.toursession

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BluetoothLanePSMsTest {
    @Test fun sharedFixtureAndLaneMapping() {
        val endpoints = BluetoothLanePSMs(admission = 128, realtime = 129, control = 256, asset = 65535)
        assertEquals("474f4c31008000810100ffff", endpoints.encode().joinToString("") { "%02x".format(it) })
        assertEquals(endpoints, BluetoothLanePSMs.decode(endpoints.encode()))
        assertEquals(128, endpoints.psm(NearbyLaneRequest.Lane.METADATA))
        assertEquals(128, endpoints.psm(NearbyLaneRequest.Lane.ADMISSION))
        assertEquals(129, endpoints.psm(NearbyLaneRequest.Lane.REALTIME))
        assertEquals(256, endpoints.psm(NearbyLaneRequest.Lane.CONTROL))
        assertEquals(65535, endpoints.psm(NearbyLaneRequest.Lane.ASSET))
        for (index in 1..100) {
            val record = BluetoothLanePSMs(index, index + 100, index + 200, index + 300)
            assertEquals(record, BluetoothLanePSMs.decode(record.encode()))
        }
    }

    @Test fun rejectsEveryTruncationTrailingBytesAndUnknownVersion() {
        val bytes = BluetoothLanePSMs(128, 129, 256, 65535).encode()
        for (length in bytes.indices) rejects { BluetoothLanePSMs.decode(bytes.copyOf(length)) }
        rejects { BluetoothLanePSMs.decode(bytes + byteArrayOf(0)) }
        for (offset in 0..3) {
            rejects { BluetoothLanePSMs.decode(bytes.copyOf().apply { this[offset] = 0 }) }
        }
    }

    @Test fun rejectsZeroAndDuplicateWireEndpoints() {
        val bytes = BluetoothLanePSMs(128, 129, 256, 65535).encode()
        for (offset in 4..10 step 2) {
            rejects { BluetoothLanePSMs.decode(bytes.copyOf().apply { this[offset] = 0; this[offset + 1] = 0 }) }
            for (other in 4 until offset step 2) {
                rejects {
                    BluetoothLanePSMs.decode(bytes.copyOf().apply {
                        this[offset] = this[other]; this[offset + 1] = this[other + 1]
                    })
                }
            }
        }
    }

    @Test fun rejectsOutOfRangeAndDuplicateConstructedEndpoints() {
        for (index in 0..3) {
            for (invalid in listOf(-1, 0, 65536, Int.MAX_VALUE)) {
                val values = mutableListOf(128, 129, 256, 65535).apply { this[index] = invalid }
                rejects { BluetoothLanePSMs(values[0], values[1], values[2], values[3]) }
            }
        }
        rejects { BluetoothLanePSMs(1, 1, 2, 3) }
    }

    private fun rejects(body: () -> Unit) { assertThrows(IllegalArgumentException::class.java, body) }
}
