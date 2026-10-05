package com.aessam.toursession

/** Software bounds, not measured radio capacity. A listener's three lanes are not three NDPs. */
object SessionCapacityPolicy {
    const val LISTENER_LIMIT = 30
    const val PERSISTENT_LANES_PER_LISTENER = 3
    const val TRANSIENT_ADMISSION_LIMIT = 8
    const val MAXIMUM_BRIDGE_CONNECTIONS = LISTENER_LIMIT * PERSISTENT_LANES_PER_LISTENER + TRANSIENT_ADMISSION_LIMIT

    /** owned includes upstream+downstream; available excludes allocated paths. upstreamReservation
     * is the total desired upstream allocation, not an extra subtraction for an existing upstream.
     * Null means unknown hardware capacity, never a fabricated universal path count.
     */
    fun usableDirectPeerLimit(hardwareMaximumPaths: Int?, availablePaths: Int?, currentlyOwnedPaths: Int,
        upstreamReservation: Int, recoveryReservation: Int = 0): Int? {
        require(currentlyOwnedPaths >= 0 && upstreamReservation >= 0 && recoveryReservation >= 0 &&
            (hardwareMaximumPaths == null || hardwareMaximumPaths >= 0) &&
            (availablePaths == null || availablePaths >= 0)) { "Invalid resource snapshot" }
        val reserved = Math.addExact(upstreamReservation, recoveryReservation)
        var limit = hardwareMaximumPaths
        require(hardwareMaximumPaths == null || currentlyOwnedPaths <= hardwareMaximumPaths) { "Invalid resource snapshot" }
        if (availablePaths != null) {
            val total = Math.addExact(availablePaths, currentlyOwnedPaths)
            require(hardwareMaximumPaths == null || total <= hardwareMaximumPaths) { "Inconsistent resource snapshot" }
            limit = limit?.let { minOf(it, total) } ?: total
        }
        return limit?.let { minOf(LISTENER_LIMIT, if (reserved >= it) 0 else it - reserved) }
    }
}
