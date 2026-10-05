#if DEBUG
import Foundation
import Network
import Security
import CryptoKit

public struct DebugRequest: Codable, Sendable {
    public let id: UUID
    public let command: String
    public let arguments: [String: String]
    public init(id: UUID = UUID(), command: String, arguments: [String: String] = [:]) {
        self.id = id; self.command = command; self.arguments = arguments
    }
}

public struct DebugResponse: Codable, Sendable {
    public let id: UUID
    public let success: Bool
    public let result: String
    public init(id: UUID, success: Bool, result: String) {
        self.id = id; self.success = success; self.result = result
    }
}

@MainActor
public protocol DebugCommandHandler: AnyObject {
    func execute(_ request: DebugRequest) throws -> String
}

public enum DebugControlError: Error { case invalidKey, invalidFrame, closed, timeout, rejected, mismatchedResponse, identityImport(Int32) }

public enum DebugTLS {
    public static func identity(pkcs12: Data, password: String) throws -> SecIdentity {
        guard #available(iOS 18, macOS 15, *) else { throw DebugControlError.rejected }
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true] as [String: Any]
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess else { throw DebugControlError.identityImport(status) }
        guard let first = (imported as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { throw DebugControlError.rejected }
        return value as! SecIdentity
    }
    public static func parameters(identity: SecIdentity? = nil, certificatePin: Data? = nil) throws -> NWParameters {
        guard (identity != nil) != (certificatePin != nil) else { throw DebugControlError.invalidKey }
        if let certificatePin, certificatePin.count != 32 { throw DebugControlError.invalidKey }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        if let identity {
            guard let protocolIdentity = sec_identity_create(identity) else { throw DebugControlError.rejected }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        }
        if let certificatePin {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let native = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certificates = SecTrustCopyCertificateChain(native) as? [SecCertificate],
                      let leaf = certificates.first else { complete(false); return }
                let bytes = SecCertificateCopyData(leaf) as Data
                complete(Data(SHA256.hash(data: bytes)) == certificatePin)
            }, .global())
        }
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

@MainActor
public final class DebugControlServer {
    private weak var handler: (any DebugCommandHandler)?
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var expiry: Task<Void, Never>?
    private var key: SymmetricKey?
    private var seen: Set<UUID> = []
    public var onState: ((String, UInt16?) -> Void)?
    public init(handler: any DebugCommandHandler) { self.handler = handler }

    public func start(key: Data, identity: SecIdentity, port: UInt16 = 50_999, lifetime: Duration = .seconds(900)) throws {
        guard listener == nil, key.count == 32 else { throw DebugControlError.rejected }
        self.key = SymmetricKey(data: key)
        let listener = try NWListener(using: DebugTLS.parameters(identity: identity),
                                      on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready: self.onState?("listening", listener?.port?.rawValue)
                case .failed: self.stop(); self.onState?("failed", nil)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, self.listener === listener, self.clients.count < 4 else {
                    connection.cancel(); return
                }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            self?.stop()
        }
    }

    public func stop() {
        expiry?.cancel(); expiry = nil
        listener?.cancel(); listener = nil
        clients.values.forEach { $0.cancel() }; clients.removeAll()
        key = nil; seen.removeAll()
        onState?("stopped", nil)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID(); clients[id] = connection
        connection.start(queue: .main)
        Task { [weak self] in
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                connection.cancel()
            }
            defer { deadline.cancel(); connection.cancel(); self?.clients.removeValue(forKey: id) }
            do {
                let envelope = try JSONDecoder().decode(DebugAuthenticatedRequest.self, from: await DebugWire.read(connection))
                guard let self, self.clients[id] === connection, let key = self.key,
                      HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: key) else {
                    throw DebugControlError.rejected
                }
                let request = try JSONDecoder().decode(DebugRequest.self, from: envelope.payload)
                guard self.seen.count < 2048, self.seen.insert(request.id).inserted,
                      let handler = self.handler else { throw DebugControlError.rejected }
                let response: DebugResponse
                do {
                    response = DebugResponse(id: request.id, success: true, result: try handler.execute(request))
                } catch {
                    // The adapter supplies deliberately non-sensitive errors, not arbitrary exception descriptions.
                    response = DebugResponse(id: request.id, success: false, result: "Command rejected; check name, arguments and current app state")
                }
                try await DebugWire.write(JSONEncoder().encode(response), to: connection)
            } catch {
                // No decoded command is ever executed after malformed framing or failed TLS.
                self?.onState?("connection-rejected", self?.listener?.port?.rawValue)
            }
        }
    }
}

public enum DebugControlClient {
    public static func send(_ request: DebugRequest, host: String, port: UInt16 = 50_999, key: Data, certificatePin: Data,
                            onState: (@Sendable (String) -> Void)? = nil) async throws -> DebugResponse {
        guard port != 0, !host.isEmpty, key.count == 32 else { throw DebugControlError.rejected }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: try DebugTLS.parameters(certificatePin: certificatePin))
        connection.stateUpdateHandler = { state in onState?(String(describing: state)) }
        connection.start(queue: .global(qos: .userInitiated))
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            connection.cancel()
        }
        defer { deadline.cancel(); connection.cancel() }
        return try await withTaskCancellationHandler {
            let payload = try JSONEncoder().encode(request)
            let envelope = DebugAuthenticatedRequest(payload: payload,
                mac: Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))))
            try await DebugWire.write(JSONEncoder().encode(envelope), to: connection)
            let response = try JSONDecoder().decode(DebugResponse.self, from: await DebugWire.read(connection))
            guard response.id == request.id else { throw DebugControlError.mismatchedResponse }
            return response
        } onCancel: { connection.cancel() }
    }
}

private struct DebugAuthenticatedRequest: Codable { let payload: Data; let mac: Data }

enum DebugWire {
    static let maximum = 32_768
    static func write(_ data: Data, to connection: NWConnection) async throws {
        guard (1...maximum).contains(data.count) else { throw DebugControlError.invalidFrame }
        var length = UInt32(data.count).bigEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    static func read(_ connection: NWConnection) async throws -> Data {
        let header = try await readExactly(4, connection)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maximum).contains(length) else { throw DebugControlError.invalidFrame }
        return try await readExactly(length, connection)
    }
    private static func readExactly(_ count: Int, _ connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { bytes, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: DebugControlError.closed) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}
#endif
