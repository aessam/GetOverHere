package com.aessam.toursession

enum class SessionTransportRoute(val rawValue: Int) {
    LOCAL_LAN(1),
    WIFI_AWARE(2),
}

data class SessionRouteAvailability(
    val hasLANHost: Boolean,
    val hasWiFiAwareSession: Boolean,
) {
    val orderedRoutes: List<SessionTransportRoute>
        get() = buildList {
            if (hasLANHost) add(SessionTransportRoute.LOCAL_LAN)
            if (hasWiFiAwareSession) add(SessionTransportRoute.WIFI_AWARE)
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
