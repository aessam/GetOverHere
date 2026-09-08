import Foundation
import Testing
@testable import TourSessionCore

@Suite struct GuideAssetScheduleTests {
    private let ordinary = String(repeating: "a", count: 64)
    private let current = String(repeating: "b", count: 64)
    private let next = String(repeating: "c", count: 64)

    @Test func fairnessPrecedesPerMemberPriorityAndFIFOTies() throws {
        var schedule = try GuideAssetSchedule()
        let a = UUID(), b = UUID()
        try schedule.register(memberID: a)
        try schedule.register(memberID: b)
        try schedule.setPriority(currentHash: current, nextHash: next)
        try schedule.enqueue(memberID: a, sha256: next, offset: 0, remainingBytes: 1)
        try schedule.enqueue(memberID: a, sha256: current, offset: 0, remainingBytes: 1)
        try schedule.enqueue(memberID: b, sha256: ordinary, offset: 0, remainingBytes: 1)
        try schedule.enqueue(memberID: b, sha256: ordinary, offset: 1, remainingBytes: 1)
        let reservations = try (0 ..< 4).map { _ in try take(&schedule, at: 0) }
        #expect(reservations.map(\.memberID) == [a, b, a, b])
        #expect(reservations.map(\.sha256) == [current, ordinary, next, ordinary])
        #expect(reservations.map(\.offset) == [0, 0, 0, 1])
    }

    @Test func dedupAndLimitIncludeInflightAndStaleCompletionCannotReleaseReplacement() throws {
        var schedule = try GuideAssetSchedule()
        let member = UUID()
        try schedule.register(memberID: member)
        let first = try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 1)
        let duplicate = try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 99)
        #expect(first && !duplicate)
        let old = try take(&schedule, at: 0)
        let activeDuplicate = try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 1)
        #expect(!activeDuplicate)
        try schedule.enqueue(memberID: member, sha256: ordinary, offset: 1, remainingBytes: 1)
        #expect(throws: GuideAssetScheduleError.memberQueueFull) {
            try schedule.enqueue(memberID: member, sha256: ordinary, offset: 2, remainingBytes: 1)
        }
        #expect(schedule.queueCount == 1 && schedule.outstandingCount == 2)
        schedule.remove(memberID: member)
        #expect(schedule.isEmpty)
        try schedule.register(memberID: member)
        try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 1)
        let replacement = try take(&schedule, at: 0)
        let stale = schedule.complete(reservationID: old.id)
        #expect(!stale && schedule.outstandingCount == 1)
        let completed = schedule.complete(reservationID: replacement.id)
        let repeated = schedule.complete(reservationID: replacement.id)
        #expect(completed && !repeated && schedule.isEmpty)
    }

    @Test func aggregateBudgetRetainsFractionalCreditAndCapsIdleBurst() throws {
        var schedule = try GuideAssetSchedule()
        let members = (0 ..< 3).map { _ in UUID() }
        for member in members {
            try schedule.register(memberID: member)
            try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 1_000_000)
        }
        let first = try take(&schedule, at: 0)
        #expect(first.byteCount == 61_440)
        let delay = try schedule.delayUntilNextReservation(nowMilliseconds: 0)
        let tooEarly = try schedule.dequeue(nowMilliseconds: 117)
        let remainingDelay = try schedule.delayUntilNextReservation(nowMilliseconds: 117)
        #expect(delay == 118 && tooEarly == nil && remainingDelay == 1)
        let second = try take(&schedule, at: 118)
        #expect(second.memberID == members[1])
        let third = try take(&schedule, at: .max)
        #expect(third.memberID == members[2])
        _ = schedule.complete(reservationID: first.id)
        try schedule.enqueue(memberID: members[0], sha256: ordinary, offset: 61_440, remainingBytes: 61_440)
        let noIdleCredit = try schedule.dequeue(nowMilliseconds: .max)
        #expect(noIdleCredit == nil)
    }

    @Test func memberLimitFairThirtyMemberRoundAndUnknownAdmission() throws {
        var schedule = try GuideAssetSchedule()
        let members = (0 ..< 30).map { _ in UUID() }
        for member in members {
            try schedule.register(memberID: member)
            try schedule.register(memberID: member)
            for offset in UInt64(0) ... 1 {
                try schedule.enqueue(memberID: member, sha256: ordinary, offset: offset, remainingBytes: 1)
            }
        }
        #expect(throws: GuideAssetScheduleError.memberLimitReached) { try schedule.register(memberID: UUID()) }
        #expect(throws: GuideAssetScheduleError.unknownMember) {
            try schedule.enqueue(memberID: UUID(), sha256: ordinary, offset: 0, remainingBytes: 1)
        }
        let reservations = try (0 ..< 60).map { _ in try take(&schedule, at: 0) }
        #expect(reservations.map(\.memberID) == members + members)
        #expect(schedule.queueCount == 0 && schedule.outstandingCount == 60 && schedule.memberCount == 30)
        let delay = try schedule.delayUntilNextReservation(nowMilliseconds: 0)
        #expect(delay == nil && !schedule.isEmpty)
        for reservation in reservations { schedule.complete(reservationID: reservation.id) }
        #expect(schedule.isEmpty)
    }

    @Test func invalidInputsAndMonotonicRegressionAreRejectedWithoutStateLoss() throws {
        #expect(throws: GuideAssetScheduleError.invalidConfiguration) { try GuideAssetSchedule(bytesPerSecond: 0) }
        #expect(throws: GuideAssetScheduleError.invalidConfiguration) { try GuideAssetSchedule(bytesPerSecond: -1) }
        #expect(throws: GuideAssetScheduleError.invalidConfiguration) { try GuideAssetSchedule(bytesPerSecond: .max) }
        var schedule = try GuideAssetSchedule()
        let member = UUID()
        try schedule.register(memberID: member)
        for invalid in ["", String(repeating: "A", count: 64), String(repeating: "é", count: 64)] {
            #expect(throws: GuideAssetScheduleError.invalidRequest) {
                try schedule.enqueue(memberID: member, sha256: invalid, offset: 0, remainingBytes: 1)
            }
        }
        #expect(throws: GuideAssetScheduleError.invalidRequest) {
            try schedule.enqueue(memberID: member, sha256: ordinary, offset: .max, remainingBytes: 1)
        }
        #expect(throws: GuideAssetScheduleError.invalidRequest) {
            try schedule.enqueue(memberID: member, sha256: ordinary, offset: UInt64(Int64.max), remainingBytes: 1)
        }
        #expect(throws: GuideAssetScheduleError.invalidRequest) {
            try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 0)
        }
        try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 7)
        #expect(throws: GuideAssetScheduleError.invalidMonotonicTime) { try schedule.dequeue(nowMilliseconds: -1) }
        _ = try schedule.delayUntilNextReservation(nowMilliseconds: 10)
        #expect(throws: GuideAssetScheduleError.invalidMonotonicTime) { try schedule.dequeue(nowMilliseconds: 9) }
        let reservation = try take(&schedule, at: 10)
        #expect(reservation.byteCount == 7)
    }

    @Test func removingNextMemberPreservesFairnessAndResetCancelsAllWork() throws {
        var schedule = try GuideAssetSchedule()
        let a = UUID(), b = UUID(), c = UUID()
        for member in [a, b, c] {
            try schedule.register(memberID: member)
            try schedule.enqueue(memberID: member, sha256: ordinary, offset: 0, remainingBytes: 1)
        }
        let old = try take(&schedule, at: 100)
        #expect(old.memberID == a)
        schedule.remove(memberID: b)
        let nextReservation = try take(&schedule, at: 100)
        #expect(nextReservation.memberID == c)
        schedule.reset()
        let stale = schedule.complete(reservationID: old.id)
        #expect(!stale && schedule.isEmpty && schedule.memberCount == 0)
        try schedule.register(memberID: a)
        try schedule.enqueue(memberID: a, sha256: ordinary, offset: 0, remainingBytes: 61_440)
        let resetReservation = try take(&schedule, at: 0)
        #expect(resetReservation.byteCount == 61_440)
    }

    @Test func boundedWakeAndNoSmallRequestStarvationBypass() throws {
        var schedule = try GuideAssetSchedule(bytesPerSecond: 1)
        let a = UUID(), b = UUID(), c = UUID()
        for member in [a, b, c] { try schedule.register(memberID: member) }
        try schedule.enqueue(memberID: a, sha256: ordinary, offset: 0, remainingBytes: 61_440)
        try schedule.enqueue(memberID: b, sha256: ordinary, offset: 0, remainingBytes: 61_440)
        try schedule.enqueue(memberID: c, sha256: ordinary, offset: 0, remainingBytes: 1)
        _ = try take(&schedule, at: 0)
        let delay = try schedule.delayUntilNextReservation(nowMilliseconds: 1000)
        let blocked = try schedule.dequeue(nowMilliseconds: 1000)
        #expect(delay == 1000 && blocked == nil)
        let full = try take(&schedule, at: 61_440_000)
        #expect(full.memberID == b)
    }

    private func take(_ schedule: inout GuideAssetSchedule, at now: Int64) throws -> GuideAssetReservation {
        let result = try schedule.dequeue(nowMilliseconds: now)
        return try #require(result)
    }
}
