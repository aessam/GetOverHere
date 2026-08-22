package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.WiFiAwareProbeFrame
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class WiFiAwareProbeFrameTest {
    @Test
    fun wireFormatMatchesCrossPlatformFixture() {
        val frame = WiFiAwareProbeFrame(
            kind = WiFiAwareProbeFrame.Kind.PROBE,
            sequence = 0x0102_0304_0506_0708,
            sentAtNanoseconds = 0x1112_1314_1516_1718,
            payload = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte()),
        )
        val expected = byteArrayOf(
            0x47, 0x4F, 0x48, 0x31,
            0x01, 0x02, 0x00, 0x00,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x00, 0x00, 0x00, 0x03,
            0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(),
        )

        assertArrayEquals(expected, frame.encode())
        assertEquals(frame, WiFiAwareProbeFrame.decode(expected))
    }

    @Test(expected = WiFiAwareProbeFrame.DecodeException::class)
    fun rejectsTruncatedPayload() {
        val encoded = WiFiAwareProbeFrame(
            kind = WiFiAwareProbeFrame.Kind.HELLO,
            sequence = 1,
            sentAtNanoseconds = 2,
            payload = byteArrayOf(3, 4),
        ).encode()

        WiFiAwareProbeFrame.decode(encoded.copyOf(encoded.size - 1))
    }
}
