package com.aessam.comeoverhere.core

data class Channel(
    val id: String,
    val name: String,
    val createdAt: Double,  // Swift reference date (seconds since 2001-01-01)
    val createdBy: String,
    val audioHostIP: String? = null
) {
    companion object {
        val TOWNSQUARE = Channel(
            id = "00000000-0000-0000-0000-000000000000",
            name = "Townsquare",
            createdAt = 0.0,
            createdBy = "system"
        )
    }
}
