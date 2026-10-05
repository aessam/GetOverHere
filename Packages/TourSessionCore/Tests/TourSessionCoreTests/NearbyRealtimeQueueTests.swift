import Foundation
import Testing
@testable import TourSessionCore

struct NearbyRealtimeQueueTests {
    @Test func dropsStaleAudioButPreservesHandshakeAndRecentFrames() throws {
        var queue = NearbyRealtimeQueue()
        try queue.offer(Data([99]), audio: false, nowMilliseconds: 0)
        for index in 0..<100 { try queue.offer(Data([UInt8(index)]), audio: true, nowMilliseconds: UInt64(index)) }
        #expect(queue.count == 8)
        #expect(queue.dropped == 93)
        #expect(queue.next(nowMilliseconds: 245) == Data([99]))
        #expect(queue.next(nowMilliseconds: 245) == Data([95]))
        #expect(queue.dropped == 95)
        #expect(queue.next(nowMilliseconds: 1_000) == nil)
    }
    @Test func reliableOverflowRejectsInsteadOfLosingHandshake() throws {
        var queue = NearbyRealtimeQueue()
        for index in 0..<8 { try queue.offer(Data([UInt8(index)]), audio: false, nowMilliseconds: 0) }
        #expect(throws: (any Error).self) { try queue.offer(Data([9]), audio: true, nowMilliseconds: 1) }
        for index in 0..<8 { #expect(queue.next(nowMilliseconds: 100_000) == Data([UInt8(index)])) }
        #expect(queue.dropped == 0)
    }
}
