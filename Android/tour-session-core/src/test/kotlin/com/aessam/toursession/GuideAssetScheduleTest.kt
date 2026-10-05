package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class GuideAssetScheduleTest {
    private val ordinary = "a".repeat(64)
    private val current = "b".repeat(64)
    private val next = "c".repeat(64)

    @Test fun fairnessPrecedesPerMemberPriorityAndFIFOTies() {
        val schedule = GuideAssetSchedule()
        val a = UUID.randomUUID(); val b = UUID.randomUUID()
        schedule.register(a); schedule.register(b)
        schedule.setPriority(current, next)
        schedule.enqueue(a, next, 0, 1); schedule.enqueue(a, current, 0, 1)
        schedule.enqueue(b, ordinary, 0, 1); schedule.enqueue(b, ordinary, 1, 1)
        val reservations = List(4) { requireNotNull(schedule.dequeue(0)) }
        assertEquals(listOf(a, b, a, b), reservations.map { it.memberId })
        assertEquals(listOf(current, ordinary, next, ordinary), reservations.map { it.sha256 })
        assertEquals(listOf(0L, 0L, 0L, 1L), reservations.map { it.offset })
    }

    @Test fun dedupAndLimitIncludeInflightAndStaleCompletionCannotReleaseReplacement() {
        val schedule = GuideAssetSchedule(); val member = UUID.randomUUID()
        schedule.register(member)
        assertTrue(schedule.enqueue(member, ordinary, 0, 1))
        assertFalse(schedule.enqueue(member, ordinary, 0, 99))
        val old = requireNotNull(schedule.dequeue(0))
        assertFalse(schedule.enqueue(member, ordinary, 0, 1))
        schedule.enqueue(member, ordinary, 1, 1)
        rejects(GuideAssetScheduleException.Reason.MEMBER_QUEUE_FULL) { schedule.enqueue(member, ordinary, 2, 1) }
        assertEquals(1, schedule.queueCount); assertEquals(2, schedule.outstandingCount)
        schedule.remove(member); assertTrue(schedule.isEmpty)
        schedule.register(member); schedule.enqueue(member, ordinary, 0, 1)
        val replacement = requireNotNull(schedule.dequeue(0))
        assertFalse(schedule.complete(old.id)); assertEquals(1, schedule.outstandingCount)
        assertTrue(schedule.complete(replacement.id)); assertFalse(schedule.complete(replacement.id))
        assertTrue(schedule.isEmpty)
    }

    @Test fun aggregateBudgetRetainsFractionalCreditAndCapsIdleBurst() {
        val schedule = GuideAssetSchedule(); val members = List(3) { UUID.randomUUID() }
        members.forEach { schedule.register(it); schedule.enqueue(it, ordinary, 0, 1_000_000) }
        val first = requireNotNull(schedule.dequeue(0))
        assertEquals(61_440, first.byteCount)
        assertEquals(118L, schedule.delayUntilNextReservation(0))
        assertNull(schedule.dequeue(117)); assertEquals(1L, schedule.delayUntilNextReservation(117))
        assertEquals(members[1], requireNotNull(schedule.dequeue(118)).memberId)
        assertEquals(members[2], requireNotNull(schedule.dequeue(Long.MAX_VALUE)).memberId)
        schedule.complete(first.id)
        schedule.enqueue(members[0], ordinary, 61_440, 61_440)
        assertNull(schedule.dequeue(Long.MAX_VALUE))
    }

    @Test fun memberLimitFairThirtyMemberRoundAndUnknownAdmission() {
        val schedule = GuideAssetSchedule(); val members = List(30) { UUID.randomUUID() }
        members.forEach { member ->
            schedule.register(member); schedule.register(member)
            (0L..1L).forEach { schedule.enqueue(member, ordinary, it, 1) }
        }
        rejects(GuideAssetScheduleException.Reason.MEMBER_LIMIT_REACHED) { schedule.register(UUID.randomUUID()) }
        rejects(GuideAssetScheduleException.Reason.UNKNOWN_MEMBER) { schedule.enqueue(UUID.randomUUID(), ordinary, 0, 1) }
        val reservations = List(60) { requireNotNull(schedule.dequeue(0)) }
        assertEquals(members + members, reservations.map { it.memberId })
        assertEquals(0, schedule.queueCount); assertEquals(60, schedule.outstandingCount); assertEquals(30, schedule.memberCount)
        assertNull(schedule.delayUntilNextReservation(0)); assertFalse(schedule.isEmpty)
        reservations.forEach { schedule.complete(it.id) }
        assertTrue(schedule.isEmpty)
    }

    @Test fun invalidInputsAndMonotonicRegressionAreRejectedWithoutStateLoss() {
        rejects(GuideAssetScheduleException.Reason.INVALID_CONFIGURATION) { GuideAssetSchedule(0) }
        rejects(GuideAssetScheduleException.Reason.INVALID_CONFIGURATION) { GuideAssetSchedule(-1) }
        val schedule = GuideAssetSchedule(); val member = UUID.randomUUID(); schedule.register(member)
        listOf("", "A".repeat(64), "é".repeat(64)).forEach { hash ->
            rejects(GuideAssetScheduleException.Reason.INVALID_REQUEST) { schedule.enqueue(member, hash, 0, 1) }
        }
        rejects(GuideAssetScheduleException.Reason.INVALID_REQUEST) { schedule.enqueue(member, ordinary, Long.MAX_VALUE, 1) }
        rejects(GuideAssetScheduleException.Reason.INVALID_REQUEST) { schedule.enqueue(member, ordinary, -1, 1) }
        rejects(GuideAssetScheduleException.Reason.INVALID_REQUEST) { schedule.enqueue(member, ordinary, 0, 0) }
        schedule.enqueue(member, ordinary, 0, 7)
        rejects(GuideAssetScheduleException.Reason.INVALID_MONOTONIC_TIME) { schedule.dequeue(-1) }
        schedule.delayUntilNextReservation(10)
        rejects(GuideAssetScheduleException.Reason.INVALID_MONOTONIC_TIME) { schedule.dequeue(9) }
        assertEquals(7, requireNotNull(schedule.dequeue(10)).byteCount)
    }

    @Test fun removingNextMemberPreservesFairnessAndResetCancelsAllWork() {
        val schedule = GuideAssetSchedule(); val a = UUID.randomUUID(); val b = UUID.randomUUID(); val c = UUID.randomUUID()
        listOf(a, b, c).forEach { schedule.register(it); schedule.enqueue(it, ordinary, 0, 1) }
        val old = requireNotNull(schedule.dequeue(100)); assertEquals(a, old.memberId)
        schedule.remove(b); assertEquals(c, requireNotNull(schedule.dequeue(100)).memberId)
        schedule.reset(); assertFalse(schedule.complete(old.id)); assertTrue(schedule.isEmpty); assertEquals(0, schedule.memberCount)
        schedule.register(a); schedule.enqueue(a, ordinary, 0, 61_440)
        assertEquals(61_440, requireNotNull(schedule.dequeue(0)).byteCount)
    }

    @Test fun boundedWakeAndNoSmallRequestStarvationBypass() {
        val schedule = GuideAssetSchedule(1); val a = UUID.randomUUID(); val b = UUID.randomUUID(); val c = UUID.randomUUID()
        listOf(a, b, c).forEach(schedule::register)
        schedule.enqueue(a, ordinary, 0, 61_440); schedule.enqueue(b, ordinary, 0, 61_440); schedule.enqueue(c, ordinary, 0, 1)
        requireNotNull(schedule.dequeue(0))
        assertEquals(1000L, schedule.delayUntilNextReservation(1000)); assertNull(schedule.dequeue(1000))
        assertEquals(b, requireNotNull(schedule.dequeue(61_440_000)).memberId)
    }

    private fun rejects(reason: GuideAssetScheduleException.Reason, block: () -> Unit) {
        val error = assertThrows(GuideAssetScheduleException::class.java, block)
        assertEquals(reason, error.reason)
    }
}
