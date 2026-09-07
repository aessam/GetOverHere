package com.aessam.toursession

/** Complete immutable sealed frames; control/handshake frames are never evicted. Caller serializes access. */
class NearbyRealtimeQueue {
    private data class Entry(val bytes: ByteArray, val audio: Boolean, val received: Long)
    private val entries = ArrayDeque<Entry>()
    var dropped: Int = 0
        private set
    val count: Int get() = entries.size

    fun offer(bytes: ByteArray, audio: Boolean, nowMilliseconds: Long) {
        require(bytes.isNotEmpty() && bytes.size <= MAXIMUM_FRAME_SIZE)
        if (entries.size == CAPACITY) {
            val index = entries.indexOfFirst { it.audio }
            require(index >= 0) { "Reliable nearby frame queue full" }
            entries.removeAt(index); dropped++
        }
        entries.addLast(Entry(bytes.copyOf(), audio, nowMilliseconds))
    }
    fun next(nowMilliseconds: Long): ByteArray? {
        while (entries.isNotEmpty()) {
            val entry = entries.removeFirst()
            if (entry.audio && nowMilliseconds >= entry.received && nowMilliseconds - entry.received > LIFETIME_MILLISECONDS) {
                dropped++; continue
            }
            return entry.bytes
        }
        return null
    }
    companion object {
        const val CAPACITY = 8
        const val MAXIMUM_FRAME_SIZE = 16_384
        const val LIFETIME_MILLISECONDS = 150L
    }
}
