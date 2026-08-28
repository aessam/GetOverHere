import Darwin
import Foundation

nonisolated enum SocketFrameOverflowPolicy: Sendable {
    case dropOldest
    case disconnect
}

nonisolated final class ManagedSocket: @unchecked Sendable {
    let fd: Int32
    let generation: UInt64

    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    init(fd: Int32, generation: UInt64) {
        self.fd = fd
        self.generation = generation
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        cancelled = true
        lock.unlock()
        Darwin.close(fd)
    }
}

nonisolated final class SocketFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Bool?

    fileprivate func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        guard semaphore.wait(timeout: timeout) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return result == true
    }
}

nonisolated final class BoundedSocketFrameWriter: @unchecked Sendable {
    private struct PendingFrame {
        let data: Data
        let delivery: SocketFrameDelivery?
    }

    let socket: ManagedSocket

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let capacity: Int
    private let overflowPolicy: SocketFrameOverflowPolicy
    private let failureHandler: @Sendable (Int32, UInt64) -> Void
    private var pending: [PendingFrame] = []
    private var draining = false
    private var stopped = false
    private var failureReported = false

    init(
        socket: ManagedSocket,
        label: String,
        capacity: Int,
        overflowPolicy: SocketFrameOverflowPolicy,
        sendTimeoutMilliseconds: Int,
        failureHandler: @escaping @Sendable (Int32, UInt64) -> Void
    ) {
        precondition(capacity > 0)
        precondition(sendTimeoutMilliseconds > 0)
        self.socket = socket
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.capacity = capacity
        self.overflowPolicy = overflowPolicy
        self.failureHandler = failureHandler

        var timeout = timeval(
            tv_sec: sendTimeoutMilliseconds / 1_000,
            tv_usec: Int32(sendTimeoutMilliseconds % 1_000) * 1_000
        )
        setsockopt(
            socket.fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    @discardableResult
    func enqueue(_ data: Data, trackDelivery: Bool = false) -> SocketFrameDelivery? {
        let delivery = trackDelivery ? SocketFrameDelivery() : nil
        var dropped: SocketFrameDelivery?
        var shouldSchedule = false
        var shouldFail = false

        lock.lock()
        if stopped {
            lock.unlock()
            delivery?.resolve(false)
            return delivery
        }
        if pending.count >= capacity {
            switch overflowPolicy {
            case .dropOldest:
                dropped = pending.removeFirst().delivery
            case .disconnect:
                shouldFail = true
            }
        }
        if !shouldFail {
            pending.append(PendingFrame(data: data, delivery: delivery))
            if !draining {
                draining = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        dropped?.resolve(false)
        if shouldFail {
            delivery?.resolve(false)
            fail()
            return delivery
        }
        if shouldSchedule {
            queue.async { [weak self] in self?.drain() }
        }
        return delivery
    }

    func stop() {
        let abandoned: [SocketFrameDelivery]
        let closeImmediately: Bool
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        abandoned = pending.compactMap(\.delivery)
        pending.removeAll(keepingCapacity: false)
        closeImmediately = !draining
        lock.unlock()

        abandoned.forEach { $0.resolve(false) }
        socket.cancel()
        if closeImmediately {
            queue.async { [socket] in socket.close() }
        }
    }

    private func drain() {
        while true {
            let item: PendingFrame
            lock.lock()
            if stopped || pending.isEmpty {
                draining = false
                let shouldClose = stopped
                lock.unlock()
                if shouldClose { socket.close() }
                return
            }
            item = pending.removeFirst()
            lock.unlock()

            let sent = SocketFrameIO.writeFrame(socket: socket, data: item.data)
            item.delivery?.resolve(sent)
            if !sent {
                fail()
                socket.close()
                return
            }
        }
    }

    private func fail() {
        var shouldReport = false
        lock.lock()
        if !failureReported {
            failureReported = true
            shouldReport = true
        }
        lock.unlock()
        stop()
        if shouldReport {
            failureHandler(socket.fd, socket.generation)
        }
    }
}

nonisolated enum SocketFrameIO {
    static func writeFrame(socket: ManagedSocket, data: Data) -> Bool {
        guard data.count <= Int(UInt32.max), !socket.isCancelled else { return false }
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        return writeAll(socket: socket, data: header) && writeAll(socket: socket, data: data)
    }

    private static func writeAll(socket: ManagedSocket, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count, !socket.isCancelled {
                let written = Darwin.send(
                    socket.fd,
                    base.advanced(by: offset),
                    data.count - offset,
                    MSG_NOSIGNAL
                )
                if written <= 0 { return false }
                offset += written
            }
            return offset == data.count
        }
    }
}
