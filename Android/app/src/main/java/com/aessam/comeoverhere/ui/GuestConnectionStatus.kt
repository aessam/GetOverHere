package com.aessam.comeoverhere.ui

import com.aessam.comeoverhere.service.SessionConnectionState

/**
 * Guest header status text. A FAILED state renders the recorded failure reason, so a
 * protocol version mismatch is visible instead of the generic label.
 */
fun guestConnectionStatusText(
    state: SessionConnectionState,
    reconnectAttempt: Int,
    error: String?,
): String = when (state) {
    SessionConnectionState.IDLE -> "IDLE"
    SessionConnectionState.CONNECTING -> "CONNECTING"
    SessionConnectionState.CONNECTED -> "LISTENING"
    SessionConnectionState.RECONNECTING -> "RECONNECTING $reconnectAttempt/5"
    SessionConnectionState.FAILED -> error ?: "CONNECTION FAILED"
}
