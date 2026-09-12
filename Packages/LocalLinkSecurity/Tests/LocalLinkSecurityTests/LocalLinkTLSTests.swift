import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import LocalLinkSecurity

@Suite(.serialized) @MainActor
struct LocalLinkTLSTests {
    enum Mode: CaseIterable { case valid, wrongServerPin, wrongClientPin, missingClientCertificate, expiredServerCertificate }

    @Test(arguments: Mode.allCases)
    func mutualTLSRequiresBothExpectedValidIdentities(_ mode: Mode) async throws {
        let serverDate = mode == .expiredServerCertificate ? Date().addingTimeInterval(-400 * 86_400) : Date()
        let server = try LocalLinkIdentity(privateKey: .init(), now: serverDate)
        let client = try LocalLinkIdentity(privateKey: .init())
        let serverPin = mode == .wrongServerPin ? Data(repeating: 0, count: 32) : server.certificateFingerprint
        let clientPin = mode == .wrongClientPin ? Data(repeating: 0, count: 32) : client.certificateFingerprint
        let serverTLS = try server.tlsOptions(expectedPeerPin: clientPin)
        let clientTLS: NWProtocolTLS.Options
        if mode == .missingClientCertificate {
            clientTLS = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(clientTLS.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_verify_block(clientTLS.securityProtocolOptions, { _, trust, complete in
                let value = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(value) as? [SecCertificate], let leaf = chain.first,
                      let pin = try? LocalLinkIdentity.fingerprint(certificate: leaf) else { complete(false); return }
                complete(pin == serverPin)
            }, .main)
        } else { clientTLS = try client.tlsOptions(expectedPeerPin: serverPin) }

        let fixture = try TLSFixture(serverTLS: serverTLS)
        defer { fixture.close() }
        let port = try await fixture.start()
        let connection = NWConnection(host: "127.0.0.1", port: port,
            using: NWParameters(tls: clientTLS, tcp: NWProtocolTCP.Options()))
        fixture.client = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting(.tls): connection.cancel()
            default: break
            }
        }
        connection.start(queue: .main)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)); fixture.timedOut = true; fixture.close() } catch { return }
        }
        defer { deadline.cancel() }
        let message = Data("authenticated wired bytes".utf8)
        do {
            let echo = try await fixture.echo(message)
            #expect(mode == .valid)
            #expect(echo == message)
        } catch {
            #expect(mode != .valid, "Correctly pinned mutually authenticated TLS must exchange actual bytes: \(error)")
        }
        #expect(!fixture.timedOut, "TLS rejection must be observed without the fixture deadline: \(mode)")
    }
}

@MainActor private final class TLSFixture {
    let listener: NWListener
    var client: NWConnection?
    var servers: [NWConnection] = []
    var ready: CheckedContinuation<NWEndpoint.Port, any Error>?
    var timedOut = false
    init(serverTLS: NWProtocolTLS.Options) throws {
        listener = try NWListener(using: NWParameters(tls: serverTLS, tcp: NWProtocolTCP.Options()), on: .any)
    }
    func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.servers.append(connection); connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, _, error in
                    guard error == nil, let data else { connection.cancel(); return }
                    connection.send(content: data, completion: .contentProcessed { error in
                        if error != nil { connection.cancel() }
                    })
                }
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, let ready = self.ready else { return }
                switch state {
                case .ready:
                    self.ready = nil
                    guard let port = self.listener.port else { ready.resume(throwing: LocalLinkSecurityError.invalidIdentity); return }
                    ready.resume(returning: port)
                case .failed(let error): self.ready = nil; ready.resume(throwing: error)
                case .cancelled: self.ready = nil; ready.resume(throwing: CancellationError())
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation; listener.start(queue: .main)
        }
    }
    func echo(_ message: Data) async throws -> Data {
        guard let client else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.send(content: message, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        return try await withCheckedThrowingContinuation { continuation in
            client.receive(minimumIncompleteLength: message.count, maximumLength: message.count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }
    func close() { client?.cancel(); servers.forEach { $0.cancel() }; listener.cancel() }
}
