import Foundation
import Network

/// A locator only. A Bonjour name never replaces the enrolled certificate pins.
@MainActor
protocol WiredHubDiscovering: AnyObject {
    func endpoint(pairingID: UUID, interface: NWInterface) async throws -> NWEndpoint
    func stop()
}

@MainActor
final class WiredHubDiscovery: WiredHubDiscovering {
    static let serviceType = "_goh-hub._tcp"
    static func instanceName(_ pairingID: UUID) -> String { "goh-" + pairingID.uuidString.lowercased() }
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<NWEndpoint, any Error>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0

    static func matches(_ endpoint: NWEndpoint, pairingID: UUID, interface: NWInterface) -> Bool {
        guard case let .service(name, type, domain, source) = endpoint,
              name == instanceName(pairingID), type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == serviceType,
              domain == "local." || domain == "local", let source,
              source.index == interface.index, source.type == interface.type else { return false }
        return true
    }

    func endpoint(pairingID: UUID, interface: NWInterface) async throws -> NWEndpoint {
        stop()
        let attempt = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let parameters = NWParameters.tcp
                parameters.requiredInterface = interface
                parameters.includePeerToPeer = false
                let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: parameters)
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    Task { @MainActor [weak self] in
                        guard let self, generation == attempt else { return }
                        for result in results {
                            guard result.interfaces.contains(where: { $0.index == interface.index && $0.type == interface.type }),
                                  case let .service(name, type, domain, _) = result.endpoint else { continue }
                            let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                            guard Self.matches(endpoint, pairingID: pairingID, interface: interface) else { continue }
                            finish(.success(endpoint)); return
                        }
                    }
                }
                browser.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, generation == attempt else { return }
                        if case .failed(let error) = state { finish(.failure(error)) }
                    }
                }
                self.browser = browser
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, generation == attempt else { return }
                    finish(.failure(NearbyConnectionError.unavailable))
                }
                browser.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, generation == attempt else { return }
                stop()
            }
        }
    }

    func stop() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<NWEndpoint, any Error>) {
        generation &+= 1
        deadline?.cancel(); deadline = nil; browser?.cancel(); browser = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
