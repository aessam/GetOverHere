import Network
import Testing
@testable import GetOverHere

@MainActor
struct WiFiAwareLifecycleTests {
    nonisolated static var supported: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }

    @Test(.enabled(if: supported)) func failedNativeOwnerCanRestartTheSameMode() async {
        guard #available(iOS 26.4, *) else { return }
        var starts = 0
        var failures: [String] = []
        let transport = WiFiAwareRoomTransport(supportsAware: { true }) { _ in
            starts += 1
            throw NWError.wifiAware(-11992)
        }
        transport.onError = { failures.append($0) }
        defer { transport.stop() }
        transport.setMode(.advertising)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == 1)
        #expect(failures.count == 1)
        transport.setMode(.advertising)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == 2)
        #expect(failures.count == 2)
    }

    @Test(.enabled(if: supported)) func cancelledOwnerCannotReportFailureForItsReplacement() async {
        guard #available(iOS 26.4, *) else { return }
        var continuations: [CheckedContinuation<Void, Never>] = []
        var failures: [String] = []
        let transport = WiFiAwareRoomTransport(supportsAware: { true }) { _ in
            await withCheckedContinuation { continuations.append($0) }
            throw NWError.wifiAware(-11992)
        }
        transport.onError = { failures.append($0) }
        defer {
            transport.stop()
            continuations.forEach { $0.resume() }
        }
        transport.setMode(.advertising)
        for _ in 0..<20 { await Task.yield() }
        transport.setMode(.browsing)
        for _ in 0..<20 { await Task.yield() }
        #expect(continuations.count == 2)
        if !continuations.isEmpty { continuations.removeFirst().resume() }
        for _ in 0..<20 { await Task.yield() }
        #expect(failures.isEmpty)
        transport.setMode(.browsing)
        for _ in 0..<20 { await Task.yield() }
        #expect(continuations.count == 1)
    }

    @Test(.enabled(if: supported)) func unexpectedSuccessfulReturnAlsoReleasesTheOwner() async {
        guard #available(iOS 26.4, *) else { return }
        var starts = 0
        var failures = 0
        let transport = WiFiAwareRoomTransport(supportsAware: { true }) { _ in starts += 1 }
        transport.onError = { _ in failures += 1 }
        defer { transport.stop() }
        transport.setMode(.browsing)
        for _ in 0..<20 { await Task.yield() }
        transport.setMode(.browsing)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == 2)
        #expect(failures == 2)
    }

    @Test(.enabled(if: supported)) func nativeCancellationWithoutLocalStopIsReportedAndRetryable() async {
        guard #available(iOS 26.4, *) else { return }
        var starts = 0
        var failures = 0
        let transport = WiFiAwareRoomTransport(supportsAware: { true }) { _ in
            starts += 1
            throw CancellationError()
        }
        transport.onError = { _ in failures += 1 }
        defer { transport.stop() }
        transport.setMode(.advertising)
        for _ in 0..<20 { await Task.yield() }
        transport.setMode(.advertising)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == 2)
        #expect(failures == 2)
    }

    @Test(.enabled(if: supported)) func capabilityRecheckDoesNotRequireModeChange() async {
        guard #available(iOS 26.4, *) else { return }
        var supported = false
        var starts = 0
        let transport = WiFiAwareRoomTransport(supportsAware: { supported }) { _ in starts += 1 }
        defer { transport.stop() }
        transport.setMode(.browsing)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == 0)
        supported = true
        transport.setMode(.browsing)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == 1)
    }
}
