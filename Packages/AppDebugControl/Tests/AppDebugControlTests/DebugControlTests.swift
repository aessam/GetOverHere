import Foundation
import Testing
@testable import AppDebugControl

@Suite(.serialized)
@MainActor
struct DebugControlTests {
    final class Handler: DebugCommandHandler {
        var calls = 0
        func execute(_ request: DebugRequest) throws -> String { calls += 1; return "{\"state\":\"ready\"}" }
    }

    @Test func authenticatedTLSRoundtripAndWrongKeyCannotExecute() async throws {
        let handler = Handler()
        let server = DebugControlServer(handler: handler)
        let key = Data(repeating: 0x34, count: 32) // Deterministic test key only.
        let directory = FileManager.default.temporaryDirectory.appending(path: "GOHDebugTLS-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not clean the owned TLS fixture directory") }
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appending(path: "scripts/create_debug_control_identity.sh").path, directory.path]
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let password = try Data(contentsOf: directory.appending(path: "control.key")).base64EncodedString()
        let identity = try DebugTLS.identity(pkcs12: Data(contentsOf: directory.appending(path: "identity.p12")), password: password)
        let pin = try Data(contentsOf: directory.appending(path: "certificate.sha256"))
        var port: UInt16?
        server.onState = { state, value in print("server-state=\(state)"); if state == "listening" { port = value } }
        try server.start(key: key, identity: identity, port: 0)
        defer { server.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while port == nil {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = DebugRequest(command: "status")
        let response = try await DebugControlClient.send(request, host: "127.0.0.1", port: #require(port), key: key, certificatePin: pin, onState: { print("client-state=\($0)") })
        #expect(response.success && response.result == "{\"state\":\"ready\"}")
        #expect(handler.calls == 1)
        let second = try await DebugControlClient.send(DebugRequest(command: "status"), host: "127.0.0.1", port: #require(port), key: key, certificatePin: pin)
        #expect(second.success && handler.calls == 2)
        await #expect(throws: (any Error).self) {
            try await DebugControlClient.send(DebugRequest(command: "status"), host: "127.0.0.1", port: #require(port), key: Data(repeating: 0x45, count: 32), certificatePin: pin)
        }
        await #expect(throws: (any Error).self) {
            try await DebugControlClient.send(request, host: "127.0.0.1", port: #require(port), key: key, certificatePin: pin)
        }
        await #expect(throws: (any Error).self) {
            try await DebugControlClient.send(DebugRequest(command: "status"), host: "127.0.0.1", port: #require(port), key: key, certificatePin: Data(repeating: 0, count: 32))
        }
        #expect(handler.calls == 2)
    }

    @Test func rejectsInvalidKeyAndRoundtripsCommands() throws {
        #expect(throws: DebugControlError.self) { try DebugTLS.parameters(certificatePin: Data()) }
        let command = DebugRequest(command: "create", arguments: ["name": "جولة 🌍"])
        let decoded = try JSONDecoder().decode(DebugRequest.self, from: JSONEncoder().encode(command))
        #expect(command.id == decoded.id && command.arguments == decoded.arguments)
    }
}
