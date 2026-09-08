package com.aessam.toursession

import java.util.UUID

class GuideAssetScheduleException(val reason: Reason) : IllegalArgumentException(reason.name) {
    enum class Reason {
        INVALID_CONFIGURATION, INVALID_REQUEST, UNKNOWN_MEMBER, MEMBER_LIMIT_REACHED,
        MEMBER_QUEUE_FULL, INVALID_MONOTONIC_TIME,
    }
}

data class GuideAssetReservation internal constructor(
    val id: UUID,
    val memberId: UUID,
    val sha256: String,
    val offset: Long,
    val byteCount: Int,
)

/** Guide-owned payload pacing, not radio QoS or measured throughput. Caller validates admission and
 * manifest membership and serializes access. In-flight work retains its slot until complete/remove.
 */
class GuideAssetSchedule(val bytesPerSecond: Int = DEFAULT_BYTES_PER_SECOND) {
    private data class Request(val sha256: String, val offset: Long, val byteCount: Int)
    private data class Candidate(val memberIndex: Int, val requestIndex: Int, val request: Request)

    private val members = mutableMapOf<UUID, MutableList<Request>>()
    private val order = mutableListOf<UUID>()
    private var nextMember = 0
    private val inFlight = mutableMapOf<UUID, GuideAssetReservation>()
    private var currentHash: String? = null
    private var nextHash: String? = null
    private var lastMilliseconds: Long? = null
    // Byte-milliseconds preserve fractional credit identically to Swift without floating point.
    private var credit = CHUNK_LIMIT * 1000L
    val queueCount: Int get() = members.values.sumOf { it.size }
    val outstandingCount: Int get() = queueCount + inFlight.size
    val isEmpty: Boolean get() = outstandingCount == 0
    val memberCount: Int get() = members.size

    init { if (bytesPerSecond <= 0) fail(GuideAssetScheduleException.Reason.INVALID_CONFIGURATION) }

    fun register(memberId: UUID) {
        if (memberId in members) return
        if (members.size >= MEMBER_LIMIT) fail(GuideAssetScheduleException.Reason.MEMBER_LIMIT_REACHED)
        members[memberId] = mutableListOf()
        order.add(memberId)
    }

    fun remove(memberId: UUID) {
        val index = order.indexOf(memberId)
        if (index < 0) return
        members.remove(memberId)
        order.removeAt(index)
        inFlight.entries.removeAll { it.value.memberId == memberId }
        if (index < nextMember) nextMember -= 1
        if (nextMember >= order.size) nextMember = 0
    }

    fun reset() {
        members.clear()
        order.clear()
        inFlight.clear()
        nextMember = 0
        currentHash = null
        nextHash = null
        lastMilliseconds = null
        credit = CHUNK_LIMIT * 1000L
    }

    fun setPriority(currentHash: String?, nextHash: String?) {
        listOfNotNull(currentHash, nextHash).forEach(::validateHash)
        this.currentHash = currentHash
        this.nextHash = nextHash
    }

    /** False is an existing queued/in-flight (member,hash,offset), not a new allocation. */
    fun enqueue(memberId: UUID, sha256: String, offset: Long, remainingBytes: Long): Boolean {
        val pending = members[memberId] ?: fail(GuideAssetScheduleException.Reason.UNKNOWN_MEMBER)
        validateHash(sha256)
        if (offset < 0 || remainingBytes <= 0 || offset > Long.MAX_VALUE - remainingBytes) {
            fail(GuideAssetScheduleException.Reason.INVALID_REQUEST)
        }
        val active = inFlight.values.filter { it.memberId == memberId }
        if (pending.any { it.sha256 == sha256 && it.offset == offset } ||
            active.any { it.sha256 == sha256 && it.offset == offset }) return false
        if (pending.size + active.size >= OUTSTANDING_PER_MEMBER) fail(GuideAssetScheduleException.Reason.MEMBER_QUEUE_FULL)
        pending.add(Request(sha256, offset, minOf(remainingBytes, CHUNK_LIMIT.toLong()).toInt()))
        return true
    }

    /** Member fairness first, current/next/FIFO within the selected member. A large request retains
     * its turn while awaiting credit; smaller requests cannot jump ahead and starve it.
     */
    fun dequeue(nowMilliseconds: Long): GuideAssetReservation? {
        refill(nowMilliseconds)
        val selected = candidate() ?: return null
        val cost = selected.request.byteCount * 1000L
        if (credit < cost) return null
        credit -= cost
        val member = order[selected.memberIndex]
        members.getValue(member).removeAt(selected.requestIndex)
        nextMember = (selected.memberIndex + 1) % order.size
        return GuideAssetReservation(UUID.randomUUID(), member, selected.request.sha256,
            selected.request.offset, selected.request.byteCount).also { inFlight[it.id] = it }
    }

    /** Null means no queued work; zero means ready; otherwise schedule a bounded asynchronous wake. */
    fun delayUntilNextReservation(nowMilliseconds: Long): Long? {
        refill(nowMilliseconds)
        val selected = candidate() ?: return null
        val missing = maxOf(0, selected.request.byteCount * 1000L - credit)
        val rate = bytesPerSecond.toLong()
        return minOf(MAXIMUM_WAKE_DELAY_MILLISECONDS, (missing + rate - 1) / rate)
    }

    /** Stale completion cannot release a slot belonging to a replaced member/reservation. */
    fun complete(reservationId: UUID): Boolean = inFlight.remove(reservationId) != null

    private fun candidate(): Candidate? {
        if (order.isEmpty()) return null
        for (delta in order.indices) {
            val index = (nextMember + delta) % order.size
            val requests = members.getValue(order[index])
            if (requests.isEmpty()) continue
            var selected = 0
            requests.indices.forEach { if (priority(requests[it]) < priority(requests[selected])) selected = it }
            return Candidate(index, selected, requests[selected])
        }
        return null
    }

    private fun priority(request: Request): Int = when (request.sha256) {
        currentHash -> 0
        nextHash -> 1
        else -> 2
    }

    private fun refill(now: Long) {
        if (now < 0 || lastMilliseconds?.let { now < it } == true) {
            fail(GuideAssetScheduleException.Reason.INVALID_MONOTONIC_TIME)
        }
        lastMilliseconds?.let { previous ->
            val missing = CHUNK_LIMIT * 1000L - credit
            val rate = bytesPerSecond.toLong()
            val elapsed = now - previous
            // Saturate before multiplication so even a jump to Long.MAX_VALUE cannot overflow.
            if (elapsed >= (missing + rate - 1) / rate) credit = CHUNK_LIMIT * 1000L
            else credit += elapsed * rate
        }
        lastMilliseconds = now
    }

    companion object {
        const val MEMBER_LIMIT = 30
        const val OUTSTANDING_PER_MEMBER = 2
        const val CHUNK_LIMIT = 60 * 1024
        const val DEFAULT_BYTES_PER_SECOND = 512 * 1024
        const val MAXIMUM_WAKE_DELAY_MILLISECONDS = 1000L

        private fun validateHash(value: String) {
            if (value.length != 64 || !value.all { it in '0'..'9' || it in 'a'..'f' }) {
                fail(GuideAssetScheduleException.Reason.INVALID_REQUEST)
            }
        }

        private fun fail(reason: GuideAssetScheduleException.Reason): Nothing = throw GuideAssetScheduleException(reason)
    }
}
