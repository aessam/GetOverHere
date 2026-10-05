import Foundation
import Testing
@testable import GetOverHere

@MainActor
struct NearbyRealtimeConnectionTests {
    @Test func fourFramesInFlightRequireAcknowledgementBeforeFifth() async throws {
        let (left, right) = TestNearbyPipe.pair()
        let framed = NearbyRealtimeConnection(left)
        defer { framed.close(); right.close() }
        for value in 0..<4 {
            try await framed.write(frame(value))
            #expect(try await right.readExactly(84) == frame(value))
        }
        var started = false
        var completed = false
        let fifth = Task { started = true; try await framed.write(frame(4)); completed = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(started && !completed)
        #expect(left.dataWrites == 4)
        try await right.write(Data(repeating: 0, count: 4))
        try await fifth.value
        #expect(try await right.readExactly(84) == frame(4))
    }

    @Test func acknowledgementsNeverReachApplicationBytesInEitherDirection() async throws {
        let (left, right) = TestNearbyPipe.pair()
        let first = NearbyRealtimeConnection(left)
        let second = NearbyRealtimeConnection(right)
        defer { first.close(); second.close() }
        for value in 0..<500 {
            try await first.write(frame(value))
            #expect(try await second.readExactly(84) == frame(value))
            try await second.write(frame(255 - value))
            #expect(try await first.readExactly(84) == frame(255 - value))
        }
    }

    @Test func anUnacknowledgedFrameClosesTheNativeConnection() async throws {
        let (left, right) = TestNearbyPipe.pair()
        let framed = NearbyRealtimeConnection(left)
        defer { framed.close(); right.close() }
        try await framed.write(frame(1))
        _ = try await right.readExactly(84)
        await #expect(throws: (any Error).self) { try await right.readExactly(4) }
        #expect(left.closed)
    }

    private func frame(_ value: Int) -> Data {
        Data([0, 0, 0, 80]) + Data(repeating: UInt8(truncatingIfNeeded: value), count: 80)
    }
}

/// Deterministic byte-pipe double, not a fake admission, codec or radio acceptance test.
@MainActor
private final class TestNearbyPipe: NearbyByteConnection {
    weak var peer: TestNearbyPipe?
    var closed = false
    var dataWrites = 0
    private var bytes = Data()
    private var reader: CheckedContinuation<Data, any Error>?
    private var maximum = 0
    static func pair() -> (TestNearbyPipe, TestNearbyPipe) {
        let first = TestNearbyPipe(); let second = TestNearbyPipe()
        first.peer = second; second.peer = first
        return (first, second)
    }
    func read(maximum: Int) async throws -> Data {
        guard !closed else { throw NearbyConnectionError.closed }
        precondition(reader == nil)
        return try await withCheckedThrowingContinuation { reader = $0; self.maximum = maximum; deliver() }
    }
    func write(_ bytes: Data) async throws {
        guard !closed, let peer, !peer.closed else { throw NearbyConnectionError.closed }
        if bytes.count > 4 { dataWrites += 1 }
        peer.bytes.append(bytes); peer.deliver()
    }
    private func deliver() {
        guard let reader, !bytes.isEmpty else { return }
        let part = Data(bytes.prefix(maximum)); bytes.removeFirst(part.count)
        self.reader = nil; reader.resume(returning: part)
    }
    func close() {
        guard !closed else { return }; closed = true
        let waiting = reader; reader = nil; waiting?.resume(throwing: NearbyConnectionError.closed)
        peer?.close()
    }
}
