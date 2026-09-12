package com.aessam.toursession

enum class SessionTransportRoute(val rawValue: Int) {
    LOCAL_LAN(1),
    WIFI_AWARE(2),
    BLUETOOTH(3),
    APPLE_PEER(4),
}

data class SessionRouteAvailability(
    val hasLANHost: Boolean,
    val hasWiFiAwareSession: Boolean,
    val hasBluetooth: Boolean = false,
    val hasApplePeerSession: Boolean = false,
) {
    val orderedRoutes: List<SessionTransportRoute>
        get() = buildList {
            if (hasLANHost) add(SessionTransportRoute.LOCAL_LAN)
            if (hasWiFiAwareSession) add(SessionTransportRoute.WIFI_AWARE)
            if (hasApplePeerSession) add(SessionTransportRoute.APPLE_PEER)
            if (hasBluetooth) add(SessionTransportRoute.BLUETOOTH)
        }
}

/** Explicit product selection. A failed allowed transport cannot choose a disallowed fallback. */
data class AllowedTransportPolicy(val routes: Set<SessionTransportRoute>) {
    fun permits(route: SessionTransportRoute): Boolean = route in routes
    fun filtered(candidates: List<SessionTransportRoute>): List<SessionTransportRoute> = candidates.filter(::permits)
    companion object {
        val AUTOMATIC = AllowedTransportPolicy(SessionTransportRoute.entries.toSet())
        val ANDROID_AWARE_ONLY = AllowedTransportPolicy(setOf(SessionTransportRoute.WIFI_AWARE))
        val APPLE_PEER_ONLY = AllowedTransportPolicy(setOf(SessionTransportRoute.APPLE_PEER))
    }
}

/** A single route owns realtime, control, and asset lanes for one guest session. */
class SessionRouteLease {
    var selectedRoute: SessionTransportRoute? = null
        private set

    fun select(route: SessionTransportRoute): Boolean {
        val selected = selectedRoute
        if (selected != null) return selected == route
        selectedRoute = route
        return true
    }

    fun reset() {
        selectedRoute = null
    }
}
