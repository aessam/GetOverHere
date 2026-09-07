import Foundation
import os
import TourSessionCore

/// Native-hop acknowledgements bound radio buffers independently of the local socket queues.
/// A zero-length record acknowledges one complete frame and never reaches the application lane.
@MainActor
final class NearbyRealtimeConnection: NearbyByteConnection {
    private let native: any NearbyByteConnection
    private var receiver: Task<Void, Never>?
    private var closed = false
    private var pending: [(UUID, Task<Void, Never>)] = []
    private var windowWaiter: CheckedContinuation<Void, Never>?
    private var packets: [Data] = []
    private var input = Data()
    private var readMaximum = 0
    private var reader: CheckedContinuation<Data, any Error>?
    private var writing = false
    private var writers: [CheckedContinuation<Void, Never>] = []

    init(_ native: any NearbyByteConnection) {
        self.native = native
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while !closed {
                    let prefix = try await native.readExactly(4)
                    let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
                    if length == 0 {
                        guard !pending.isEmpty else { throw NearbyConnectionError.rejected }
                        pending.removeFirst().1.cancel()
                        let waiter = windowWaiter; windowWaiter = nil; waiter?.resume()
                    } else {
                        guard (70...(NearbyRealtimeQueue.maximumFrameSize - 4)).contains(length), packets.count < 8 else {
                            throw NearbyConnectionError.capacity
                        }
                        let body = try await native.readExactly(length)
                        packets.append(prefix + body)
                        deliverRead()
                        try await sendNative(Data(repeating: 0, count: 4))
                    }
                }
            } catch {
                if !closed { Logger.transport.error("Nearby realtime flow control ended (\(String(describing: type(of: error))))") }
                close()
            }
        }
    }

    func read(maximum: Int) async throws -> Data {
        guard !closed else { throw NearbyConnectionError.closed }
        precondition(reader == nil && (1...16_384).contains(maximum))
        return try await withCheckedThrowingContinuation { continuation in
            reader = continuation; readMaximum = maximum; deliverRead()
        }
    }
    private func deliverRead() {
        guard let reader else { return }
        if input.isEmpty && !packets.isEmpty { input = packets.removeFirst() }
        guard !input.isEmpty else { return }
        let count = min(readMaximum, input.count)
        let bytes = Data(input.prefix(count)); input.removeFirst(count)
        self.reader = nil; reader.resume(returning: bytes)
    }
    func write(_ bytes: Data) async throws {
        guard !closed, (74...NearbyRealtimeQueue.maximumFrameSize).contains(bytes.count),
              bytes.prefix(4).reduce(0, { ($0 << 8) | Int($1) }) == bytes.count - 4 else {
            throw NearbyConnectionError.rejected
        }
        if pending.count >= 4 {
            precondition(windowWaiter == nil)
            await withCheckedContinuation { windowWaiter = $0 }
        }
        guard !closed else { throw NearbyConnectionError.closed }
        let id = UUID()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self, pending.contains(where: { $0.0 == id }) else { return }
            Logger.transport.error("Nearby frame acknowledgement timed out")
            close()
        }
        pending.append((id, deadline))
        try await sendNative(bytes)
    }
    private func sendNative(_ bytes: Data) async throws {
        if writing { await withCheckedContinuation { writers.append($0) } }
        else { writing = true }
        defer {
            if writers.isEmpty { writing = false }
            else { writers.removeFirst().resume() }
        }
        guard !closed else { throw NearbyConnectionError.closed }
        try await native.write(bytes)
    }
    func close() {
        guard !closed else { return }
        closed = true
        receiver?.cancel(); receiver = nil
        pending.forEach { $0.1.cancel() }; pending.removeAll()
        let waiting = windowWaiter; windowWaiter = nil; waiting?.resume()
        let reading = reader; reader = nil; reading?.resume(throwing: NearbyConnectionError.closed)
        writers.forEach { $0.resume() }; writers.removeAll()
        packets.removeAll(); input = Data()
        native.close()
    }
}
