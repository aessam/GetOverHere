package com.aessam.comeoverhere.core

import java.util.UUID
import com.aessam.toursession.SessionTransportRoute
import com.aessam.toursession.BluetoothRoomRecord

class NearbyRoomMetadataMismatch(val reason: Reason) : IllegalStateException(when (reason) {
    Reason.ROOM_CHANGED -> "The nearby room changed. Return to the room list and select the tour again."
    Reason.GUIDE_CHANGED -> "The nearby guide changed. Leave this session and confirm the room with your guide."
    Reason.ADMISSION_VERSION_UNSUPPORTED -> "This nearby room uses an incompatible admission version. Update both apps and try again."
}) {
    enum class Reason { ROOM_CHANGED, GUIDE_CHANGED, ADMISSION_VERSION_UNSUPPORTED }
}

/** Reachability/selection check only. Actual guide-key proof is still admission v2's responsibility. */
object NearbyRoomMetadataPolicy {
    fun validate(record: BluetoothRoomRecord, roomID: UUID, expectedGuideID: UUID) {
        if (record.roomID != roomID) throw NearbyRoomMetadataMismatch(NearbyRoomMetadataMismatch.Reason.ROOM_CHANGED)
        if (record.guideID != expectedGuideID) throw NearbyRoomMetadataMismatch(NearbyRoomMetadataMismatch.Reason.GUIDE_CHANGED)
        if (record.admissionVersion != 2) {
            throw NearbyRoomMetadataMismatch(NearbyRoomMetadataMismatch.Reason.ADMISSION_VERSION_UNSUPPORTED)
        }
    }
}

/** Loopback is only the adapter endpoint. Transport records the actual radio carrying the tour. */
data class NearbyGuestRoute(
    val adapterHost: String,
    val transport: SessionTransportRoute,
    val roomID: UUID,
    val routeID: UUID,
) {
    init {
        require(adapterHost == "127.0.0.1") { "A nearby adapter must use its owned IPv4 loopback endpoint" }
        require(transport == SessionTransportRoute.WIFI_AWARE || transport == SessionTransportRoute.BLUETOOTH)
    }
}

interface NearbyRouteControl {
    val usesBluetoothGuestRoute: Boolean
    val activeNearbyGuestRoute: NearbyGuestRoute? get() = null
    val awareSettings: NearbyAwareSettings?
    fun canConnectNearby(roomID: UUID): Boolean
    suspend fun prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID): NearbyGuestRoute
    fun stopNearbyGuest()
}
