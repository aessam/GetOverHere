import Darwin
import Foundation
import os
import TourSessionCore

nonisolated protocol RoomAdmissionInterface: Sendable {
    func start(sessionID: UUID, sessionCode: String) throws
    func update(policy: RoomAccessPolicy) throws
    func stop()
    func join(host: String, sessionID: UUID, code: String?) throws -> String
}

/// Bounded, short-lived bootstrap sockets; existing media lanes are deliberately untouched.
nonisolated final class RoomAdmissionTransport: RoomAdmissionInterface, @unchecked Sendable {
    private let lock = NSLock()
    private let slots = HandshakeSlots(limit: 8)
    private var listener: ManagedSocket?
    private var pending: [Int32: ManagedSocket] = [:]
    private var policy: RoomAccessPolicy?
    private var revision: UInt64 = 0
    private let port: UInt16

    init(port: UInt16 = RoomAdmission.port) { self.port = port }

    func start(sessionID: UUID, sessionCode: String) throws {
        stop()
        let open = try RoomAccessPolicy(sessionID: sessionID, code: nil)
        let socket = try Self.makeSocket()
        var yes: Int32 = 1
        setsockopt(socket.fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.address(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, Darwin.listen(socket.fd, 8) == 0 else {
            socket.close()
            throw TransportError.failed("Cannot open room admission port \(port).")
        }
        lock.withLock { listener = socket; policy = open; revision &+= 1 }
        DispatchQueue(label: "room.admission.accept", qos: .userInitiated).async { [weak self] in
            defer { socket.close() }
            while !socket.isCancelled {
                let fd = Darwin.accept(socket.fd, nil, nil)
                guard fd >= 0 else {
                    if !socket.isCancelled { Logger.transport.error("Room admission accept failed") }
                    break
                }
                guard let self, self.slots.tryAcquire() else { Darwin.close(fd); continue }
                let client = ManagedSocket(fd: fd, generation: 0)
                Self.setTimeouts(client)
                let snapshot: (RoomAccessPolicy, UInt64)? = self.lock.withLock {
                    guard self.listener === socket, let policy = self.policy else { return nil }
                    self.pending[fd] = client
                    return (policy, self.revision)
                }
                guard let snapshot else { client.close(); self.slots.release(); continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        _ = self.lock.withLock { self.pending.removeValue(forKey: fd) }
                        client.close()
                        self.slots.release()
                    }
                    do {
                        let guide = RoomAdmission.Guide(sessionID: sessionID, policy: snapshot.0)
                        try Self.write(client, guide.challenge)
                        let request = try Self.read(client, count: RoomAdmission.requestSize)
                        let reply = try guide.reply(to: request, sessionCode: sessionCode)
                        let flags = fcntl(client.fd, F_GETFL, 0)
                        guard flags >= 0, fcntl(client.fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                            throw RoomAdmissionError.invalidMessage
                        }
                        // Serialize admission completion with lock/code changes. No old-policy
                        // response can be sent after update returns to the guide's UI.
                        try self.lock.withLock {
                            guard self.listener === socket, self.revision == snapshot.1 else {
                                throw RoomAdmissionError.changed
                            }
                            try Self.writeReplyOnce(client.fd, reply)
                        }
                    } catch {
                        Logger.transport.notice("Room admission rejected or disconnected")
                    }
                }
            }
        }
    }

    func update(policy: RoomAccessPolicy) throws {
        try lock.withLock {
            guard listener != nil else { throw RoomAdmissionError.changed }
            self.policy = policy
            revision &+= 1
            pending.values.forEach { $0.cancel() }
        }
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
            policy = nil
            revision &+= 1
            pending.values.forEach { $0.cancel() }
        }
    }

    func join(host: String, sessionID: UUID, code: String?) throws -> String {
        let socket = try Self.makeSocket()
        defer { socket.close() }
        var address = Self.address(port: port)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw RoomAdmissionError.invalidMessage }
        // Nonblocking connect with a hard deadline, including unreachable guide addresses.
        let flags = fcntl(socket.fd, F_GETFL, 0)
        guard flags >= 0, fcntl(socket.fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw RoomAdmissionError.invalidMessage }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw TransportError.failed("Cannot reach the guide. Try again.") }
            var descriptor = pollfd(fd: socket.fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, 5_000) > 0 else { throw TransportError.failed("Room admission timed out.") }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket.fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw TransportError.failed("Cannot reach the guide. Try again.")
            }
        }
        guard fcntl(socket.fd, F_SETFL, flags) == 0 else { throw RoomAdmissionError.invalidMessage }
        let challenge = try Self.read(socket, count: RoomAdmission.challengeSize)
        let guest = try RoomAdmission.Guest(challenge: challenge, sessionID: sessionID, code: code)
        try Self.write(socket, guest.request)
        return try guest.open(Self.read(socket, count: RoomAdmission.replySize))
    }

    private enum TransportError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case let .failed(message): message } }
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        return address
    }

    private static func makeSocket() throws -> ManagedSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.failed("Cannot create room admission socket.") }
        let socket = ManagedSocket(fd: fd, generation: 0)
        setTimeouts(socket)
        return socket
    }

    private static func setTimeouts(_ socket: ManagedSocket) {
        var yes: Int32 = 1
        setsockopt(socket.fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func read(_ socket: ManagedSocket, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while offset < count {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw RoomAdmissionError.invalidMessage }
            let parts = remaining.components
            var timeout = timeval(tv_sec: Int(parts.seconds), tv_usec: max(1, Int32(parts.attoseconds / 1_000_000_000_000)))
            setsockopt(socket.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let received = bytes.withUnsafeMutableBytes { recv(socket.fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard received > 0 else { throw RoomAdmissionError.invalidMessage }
            offset += received
        }
        return Data(bytes)
    }

    /// One nonblocking send under the policy lock. Partial delivery fails closed: a guest
    /// cannot open an incomplete AEAD reply. Never wait for a slow peer while holding the lock.
    static func writeReplyOnce(_ fd: Int32, _ data: Data) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, flags & O_NONBLOCK != 0, data.count == RoomAdmission.replySize else {
            throw RoomAdmissionError.invalidMessage
        }
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
        guard sent == data.count else { throw RoomAdmissionError.invalidMessage }
    }

    private static func write(_ socket: ManagedSocket, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { send(socket.fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard sent > 0 else { throw RoomAdmissionError.invalidMessage }
            offset += sent
        }
    }
}
