import CryptoKit
import Foundation
import LocalLinkSecurity
import Network

enum FixtureError: Error { case arguments, disconnected, payloadMismatch, deadline }

@main @MainActor
struct GatewayTLSFixture {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, ["server", "client"].contains(arguments[1]),
                  let number = UInt16(arguments[2]), let port = NWEndpoint.Port(rawValue: number),
                  arguments[3].count == 64 else { throw FixtureError.arguments }
            let hex = Array(arguments[3]); var pin = Data()
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { throw FixtureError.arguments }
                pin.append(byte)
            }
            let identity = try LocalLinkIdentity(privateKey: .init())
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 10
            let parameters = NWParameters(tls: try identity.tlsOptions(expectedPeerPin: pin), tcp: tcp)
            let fixture = Fixture(parameters: parameters)
            defer { fixture.close() }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(25)); fixture.close() } catch { return }
            }
            defer { deadline.cancel() }
            let fingerprint = identity.certificateFingerprint.map { String(format: "%02x", $0) }.joined()
            if arguments[1] == "server" {
                let listener = try NWListener(using: parameters, on: port)
                fixture.listener = listener
                fixture.emit(["event": "ready", "pin": fingerprint, "role": "server"])
                let connection = try await fixture.accept(listener)
                let bytes = try await fixture.readFrame(connection)
                guard bytes == fixture.payload else { throw FixtureError.payloadMismatch }
                try await fixture.writeFrame(connection, bytes)
                // An application receipt proves the peer received the entire echo.
                guard try await fixture.read(connection, count: 1) == Data([42]) else { throw FixtureError.payloadMismatch }
            } else {
                fixture.emit(["event": "ready", "pin": fingerprint, "role": "client"])
                // The controller starts the Android listener before releasing stdin.
                guard readLine() == "GO" else { throw FixtureError.arguments }
                let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
                fixture.own(connection)
                try await fixture.writeFrame(connection, fixture.payload)
                guard try await fixture.readFrame(connection) == fixture.payload else { throw FixtureError.payloadMismatch }
                try await fixture.write(connection, Data([42]))
            }
            fixture.emit(["event": "pass", "bytes": fixture.payload.count,
                          "sha256": SHA256.hash(data: fixture.payload).map { String(format: "%02x", $0) }.joined(),
                          "scope": "apple_android_tls_over_adb_only"])
        } catch {
            FileHandle.standardError.write(Data("ERROR: gateway TLS fixture: \(error)\n".utf8)); exit(1)
        }
    }
}

@MainActor private final class Fixture {
    let parameters: NWParameters
    let payload = Data((0..<65_536).map { UInt8($0 % 251) })
    var listener: NWListener?
    var connections: [NWConnection] = []
    private var pendingAccept: CheckedContinuation<NWConnection, any Error>?
    init(parameters: NWParameters) { self.parameters = parameters }

    func emit(_ value: [String: Any]) {
        do { FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) + Data([10])) }
        catch { FileHandle.standardError.write(Data("ERROR: encoding fixture result: \(error)\n".utf8)) }
    }
    func own(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { state in
            switch state { case .failed, .waiting(.tls): connection.cancel(); default: break }
        }
        connection.start(queue: .main)
    }
    func accept(_ listener: NWListener) async throws -> NWConnection {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, let continuation = self.pendingAccept else { connection.cancel(); return }
                self.pendingAccept = nil; self.own(connection); continuation.resume(returning: connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let continuation = self.pendingAccept else { return }
                switch state {
                case .failed(let error): self.pendingAccept = nil; continuation.resume(throwing: error)
                case .cancelled: self.pendingAccept = nil; continuation.resume(throwing: FixtureError.disconnected)
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { pendingAccept = $0; listener.start(queue: .main) }
    }
    func read(_ connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { bytes, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let bytes, bytes.count == count { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: FixtureError.disconnected) }
            }
        }
    }
    func write(_ connection: NWConnection, _ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func readFrame(_ connection: NWConnection) async throws -> Data {
        let count = try await read(connection, count: 4).reduce(0) { ($0 << 8) | Int($1) }
        guard count == payload.count else { throw FixtureError.payloadMismatch }
        return try await read(connection, count: count)
    }
    func writeFrame(_ connection: NWConnection, _ bytes: Data) async throws {
        let count = UInt32(bytes.count)
        let prefix = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        try await write(connection, prefix + bytes)
    }
    func close() {
        listener?.cancel(); connections.forEach { $0.cancel() }
        if let pendingAccept { self.pendingAccept = nil; pendingAccept.resume(throwing: FixtureError.deadline) }
    }
}
