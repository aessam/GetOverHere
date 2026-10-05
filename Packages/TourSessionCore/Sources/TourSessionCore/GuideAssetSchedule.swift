import Foundation

public enum GuideAssetScheduleError: Error, Equatable {
    case invalidConfiguration
    case invalidRequest
    case unknownMember
    case memberLimitReached
    case memberQueueFull
    case invalidMonotonicTime
}

public struct GuideAssetReservation: Equatable, Sendable {
    public let id: UUID
    public let memberID: UUID
    public let sha256: String
    public let offset: UInt64
    public let byteCount: Int
}

/// Guide-owned payload pacing, not a radio QoS or throughput guarantee. The caller validates
/// admission and manifest membership and serializes access. In-flight work counts against limits
/// until completion; removing a member cancels its reservations without refunding sent-byte credit.
public struct GuideAssetSchedule: Sendable {
    public static let memberLimit = 30
    public static let outstandingPerMember = 2
    public static let chunkLimit = 60 * 1024
    public static let defaultBytesPerSecond = 512 * 1024
    public static let maximumWakeDelayMilliseconds: Int64 = 1000

    public let bytesPerSecond: Int
    public var queueCount: Int { members.values.reduce(0) { $0 + $1.count } }
    public var outstandingCount: Int { queueCount + inFlight.count }
    public var isEmpty: Bool { outstandingCount == 0 }
    public var memberCount: Int { members.count }

    private struct Request: Sendable {
        let sha256: String
        let offset: UInt64
        let byteCount: Int
    }

    private var members: [UUID: [Request]] = [:]
    private var order: [UUID] = []
    private var nextMember = 0
    private var inFlight: [UUID: GuideAssetReservation] = [:]
    private var currentHash: String?
    private var nextHash: String?
    private var lastMilliseconds: Int64?
    // Byte-milliseconds retain fractional credit without floating point or platform rounding drift.
    private var credit: Int64 = Int64(chunkLimit) * 1000

    public init(bytesPerSecond: Int = Self.defaultBytesPerSecond) throws {
        guard bytesPerSecond > 0, bytesPerSecond <= Int(Int32.max) else {
            throw GuideAssetScheduleError.invalidConfiguration
        }
        self.bytesPerSecond = bytesPerSecond
    }

    public mutating func register(memberID: UUID) throws {
        if members[memberID] != nil { return }
        guard members.count < Self.memberLimit else { throw GuideAssetScheduleError.memberLimitReached }
        members[memberID] = []
        order.append(memberID)
    }

    public mutating func remove(memberID: UUID) {
        guard let index = order.firstIndex(of: memberID) else { return }
        members.removeValue(forKey: memberID)
        order.remove(at: index)
        inFlight = inFlight.filter { $0.value.memberID != memberID }
        if index < nextMember { nextMember -= 1 }
        if nextMember >= order.count { nextMember = 0 }
    }

    public mutating func reset() {
        members.removeAll()
        order.removeAll()
        inFlight.removeAll()
        nextMember = 0
        currentHash = nil
        nextHash = nil
        lastMilliseconds = nil
        credit = Int64(Self.chunkLimit) * 1000
    }

    public mutating func setPriority(currentHash: String?, nextHash: String?) throws {
        for value in [currentHash, nextHash].compactMap({ $0 }) { try Self.validateHash(value) }
        self.currentHash = currentHash
        self.nextHash = nextHash
    }

    /// False denotes an already queued or in-flight (member, hash, offset), not a new allocation.
    @discardableResult
    public mutating func enqueue(memberID: UUID, sha256: String, offset: UInt64,
        remainingBytes: UInt64) throws -> Bool {
        guard let pending = members[memberID] else { throw GuideAssetScheduleError.unknownMember }
        try Self.validateHash(sha256)
        let (end, overflow) = offset.addingReportingOverflow(remainingBytes)
        guard remainingBytes > 0, !overflow, end <= UInt64(Int64.max) else {
            throw GuideAssetScheduleError.invalidRequest
        }
        let active = inFlight.values.filter { $0.memberID == memberID }
        if pending.contains(where: { $0.sha256 == sha256 && $0.offset == offset }) ||
            active.contains(where: { $0.sha256 == sha256 && $0.offset == offset }) { return false }
        guard pending.count + active.count < Self.outstandingPerMember else {
            throw GuideAssetScheduleError.memberQueueFull
        }
        members[memberID]?.append(Request(sha256: sha256, offset: offset,
            byteCount: Int(min(remainingBytes, UInt64(Self.chunkLimit)))))
        return true
    }

    /// Round-robin members, then current/next/FIFO within each member. A large request retains its
    /// turn while awaiting credit; repeated smaller requests cannot jump ahead and starve it.
    public mutating func dequeue(nowMilliseconds: Int64) throws -> GuideAssetReservation? {
        try refill(nowMilliseconds)
        guard let selected = candidate() else { return nil }
        let cost = Int64(selected.request.byteCount) * 1000
        guard credit >= cost else { return nil }
        credit -= cost
        let memberID = order[selected.memberIndex]
        members[memberID]?.remove(at: selected.requestIndex)
        nextMember = (selected.memberIndex + 1) % order.count
        let reservation = GuideAssetReservation(id: UUID(), memberID: memberID,
            sha256: selected.request.sha256, offset: selected.request.offset,
            byteCount: selected.request.byteCount)
        inFlight[reservation.id] = reservation
        return reservation
    }

    /// Nil: no queued work (in-flight work may remain). Zero: ready now. Otherwise a bounded delay
    /// for an asynchronous wake, never an instruction to block a service or UI thread.
    public mutating func delayUntilNextReservation(nowMilliseconds: Int64) throws -> Int64? {
        try refill(nowMilliseconds)
        guard let selected = candidate() else { return nil }
        let missing = max(0, Int64(selected.request.byteCount) * 1000 - credit)
        let rate = Int64(bytesPerSecond)
        return min(Self.maximumWakeDelayMilliseconds, (missing + rate - 1) / rate)
    }

    /// A completion from a removed/replaced member cannot release the new reservation's slot.
    @discardableResult
    public mutating func complete(reservationID: UUID) -> Bool {
        inFlight.removeValue(forKey: reservationID) != nil
    }

    private func candidate() -> (memberIndex: Int, requestIndex: Int, request: Request)? {
        guard !order.isEmpty else { return nil }
        for delta in 0 ..< order.count {
            let index = (nextMember + delta) % order.count
            guard let requests = members[order[index]], !requests.isEmpty else { continue }
            var requestIndex = 0
            for candidate in requests.indices where priority(requests[candidate]) < priority(requests[requestIndex]) {
                requestIndex = candidate
            }
            return (index, requestIndex, requests[requestIndex])
        }
        return nil
    }

    private func priority(_ request: Request) -> Int {
        if request.sha256 == currentHash { return 0 }
        if request.sha256 == nextHash { return 1 }
        return 2
    }

    private mutating func refill(_ now: Int64) throws {
        guard now >= 0, lastMilliseconds.map({ now >= $0 }) ?? true else {
            throw GuideAssetScheduleError.invalidMonotonicTime
        }
        if let previous = lastMilliseconds {
            let missing = Int64(Self.chunkLimit) * 1000 - credit
            let rate = Int64(bytesPerSecond)
            let elapsed = now - previous
            // Saturate before multiplying: even a clock jump to Int64.max cannot overflow.
            if elapsed >= (missing + rate - 1) / rate { credit = Int64(Self.chunkLimit) * 1000 }
            else { credit += elapsed * rate }
        }
        lastMilliseconds = now
    }

    private static func validateHash(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
            throw GuideAssetScheduleError.invalidRequest
        }
    }
}
