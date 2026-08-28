import Darwin
import Foundation
import Testing
@testable import GetOverHere

@Suite(.serialized)
struct SocketFrameIOTests {
    @Test("A stalled writer cannot block a healthy peer writer")
    func stalledWriterIsolation() throws {
        var stalledPair = [Int32](repeating: -1, count: 2)
        var healthyPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &stalledPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &healthyPair) == 0)
        try #require(stalledPair.allSatisfy { $0 >= 0 })
        try #require(healthyPair.allSatisfy { $0 >= 0 })

        var sendBuffer: Int32 = 2_048
        setsockopt(
            stalledPair[0],
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBuffer,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let stalledFailure = DispatchSemaphore(value: 0)
        let stalledWriter = BoundedSocketFrameWriter(
            socket: ManagedSocket(fd: stalledPair[0], generation: 11),
            label: "test.socket.stalled",
            capacity: 2,
            overflowPolicy: .dropOldest,
            sendTimeoutMilliseconds: 100
        ) { _, generation in
            #expect(generation == 11)
            stalledFailure.signal()
        }
        let healthyWriter = BoundedSocketFrameWriter(
            socket: ManagedSocket(fd: healthyPair[0], generation: 12),
            label: "test.socket.healthy",
            capacity: 2,
            overflowPolicy: .disconnect,
            sendTimeoutMilliseconds: 500
        ) { _, _ in
            Issue.record("Healthy writer failed")
        }
        defer {
            stalledWriter.stop()
            healthyWriter.stop()
            close(stalledPair[1])
            close(healthyPair[1])
        }

        stalledWriter.enqueue(Data(repeating: 0xA5, count: 4 * 1_024 * 1_024))
        let payload = Data([0x47, 0x4f, 0x48, 0x32])
        let delivery = try #require(healthyWriter.enqueue(payload, trackDelivery: true))
        #expect(delivery.wait(timeout: .now() + .seconds(1)))
        #expect(try readTestFrame(fd: healthyPair[1]) == payload)
        #expect(stalledFailure.wait(timeout: .now() + .seconds(2)) == .success)
    }
}

private enum SocketFrameTestError: Error {
    case readFailed
    case invalidLength
}

private func readTestFrame(fd: Int32) throws -> Data {
    func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard received > 0 else { throw SocketFrameTestError.readFailed }
            offset += received
        }
        return bytes
    }

    let header = try read(4)
    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, length < 1_024 else { throw SocketFrameTestError.invalidLength }
    return Data(try read(Int(length)))
}
