import Darwin
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// FND-8 (DSCN-26): only an AEAD authentication failure is a credential rejection. A guide that
/// closes the socket before the challenge is a transport failure and keeps the reconnect path.
@Suite(.serialized)
struct GuestHandshakeOutcomeTests {
    private enum TestTimeout: Error {
        case expired
        case streamEnded
    }

    @Test("Handshake EOF is a transport failure, not a credential rejection")
    @MainActor
    func handshakeEOFIsTransportFailureNotCredentialRejection() async throws {
        let port: UInt16 = 50_042
        let serverFD = try closingServer(port: port)
        let serverTask = Task { @concurrent in
            while true {
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { return }
                close(clientFD)
            }
        }
        defer {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverTask.cancel()
        }

        let sessionID = UUID()
        let guest = LocalSessionControlTransport(port: port)
        let (events, continuation) = AsyncStream.makeStream(of: SessionControlEvent.self)
        defer {
            guest.stop()
            continuation.finish()
        }
        guest.hostIP = "127.0.0.1"
        guest.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guest",
            platform: .iOS,
            credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        )
        guest.setEventHandler { continuation.yield($0) }
        guest.startGuest()

        let first = try await next(from: events, timeout: .seconds(3))
        guard case let .failed(message) = first else {
            Issue.record("EOF must surface as a transport failure, got \(first)")
            return
        }
        #expect(message.contains("invalid welcome"))

        do {
            let late = try await next(from: events, timeout: .milliseconds(500))
            if case .credentialRejected = late {
                Issue.record("EOF must never be classified as a credential rejection")
            }
        } catch TestTimeout.expired {
            // Silence is the expected outcome.
        }
    }

    private func next(from stream: AsyncStream<SessionControlEvent>, timeout: Duration) async throws -> SessionControlEvent {
        try await withThrowingTaskGroup(of: SessionControlEvent.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let element = await iterator.next() else { throw TestTimeout.streamEnded }
                return element
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeout.expired
            }
            guard let first = try await group.next() else { throw TestTimeout.streamEnded }
            group.cancelAll()
            return first
        }
    }
}

private enum ClosingServerError: Error {
    case create
    case bind
    case listen
}

private func closingServer(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ClosingServerError.create }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw ClosingServerError.bind
    }
    guard Darwin.listen(fd, 4) == 0 else {
        close(fd)
        throw ClosingServerError.listen
    }
    return fd
}
