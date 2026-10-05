package com.aessam.comeoverhere.core

/** Repeated radio-state broadcasts must not tear down an unchanged native session. */
internal class NearbyAvailabilityTracker {
    private var current: Boolean? = null
    fun seed(available: Boolean) { current = available }
    fun changed(available: Boolean): Boolean {
        val changed = current != available
        current = available
        return changed
    }
}
