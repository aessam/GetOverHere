package com.aessam.comeoverhere.core

import java.util.UUID

interface NearbyRouteControl {
    val usesBluetoothGuestRoute: Boolean
    val awareSettings: NearbyAwareSettings?
    fun canConnectNearby(roomID: UUID): Boolean
    suspend fun prepareNearbyGuest(roomID: UUID): String
    fun stopNearbyGuest()
}
