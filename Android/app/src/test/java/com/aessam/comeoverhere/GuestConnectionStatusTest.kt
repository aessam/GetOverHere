package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.ChannelService
import com.aessam.comeoverhere.service.SessionConnectionState
import com.aessam.comeoverhere.ui.guestConnectionStatusText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GuestConnectionStatusTest {
    @Test
    fun failedStateRendersVersionMismatch() {
        val message = ChannelService.versionMismatchMessage(remoteMajor = 2, localMajor = 3)
        val text = guestConnectionStatusText(SessionConnectionState.FAILED, 0, message)

        assertEquals(message, text)
        assertTrue(text.contains("remote 2"))
        assertTrue(text.contains("local 3"))
        assertTrue(text.contains("Update the older app"))
    }

    @Test
    fun genericFailure() {
        assertEquals("CONNECTION FAILED", guestConnectionStatusText(SessionConnectionState.FAILED, 0, null))
    }

    @Test
    fun reconnecting() {
        assertEquals(
            "RECONNECTING 2/5",
            guestConnectionStatusText(SessionConnectionState.RECONNECTING, 2, "Guide connection closed"),
        )
    }

    @Test
    fun connectedIgnoresStaleError() {
        assertEquals("LISTENING", guestConnectionStatusText(SessionConnectionState.CONNECTED, 0, "stale"))
        assertEquals("CONNECTING", guestConnectionStatusText(SessionConnectionState.CONNECTING, 0, "stale"))
        assertEquals("IDLE", guestConnectionStatusText(SessionConnectionState.IDLE, 0, "stale"))
    }
}
