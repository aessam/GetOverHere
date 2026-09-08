import Foundation
import Network
import os
import TourSessionCore

/// A reliable byte connection supplied by a native nearby transport. No plaintext
/// application serialization, credential storage, encryption, or nonce allocation here.
@MainActor
protocol NearbyByteConnection: AnyObject {
    func read(maximum: Int) async throws -> Data
    func write(_ bytes: Data) async throws
    func close()
}

extension NearbyByteConnection {
    func readExactly(_ count: Int) async throws -> Data {
        precondition((1...16_384).contains(count))
        var result = Data()
        while result.count < count {
            let bytes = try await read(maximum: count - result.count)
            guard !bytes.isEmpty, bytes.count <= count - result.count else {
                throw NearbyConnectionError.closed
            }
            result.append(bytes)
        }
        return result
    }
}

enum NearbyConnectionError: Error, LocalizedError {
    case closed, rejected, capacity, unavailable
    var errorDescription: String? {
        switch self {
        case .closed: "Nearby connection closed."
        case .rejected: "The nearby room ended or changed. Select it again."
        case .capacity: "Nearby connection capacity reached."
        case .unavailable: "No usable nearby connection is available."
        }
    }
}

@MainActor
final class NearbyTCPConnection: NearbyByteConnection {
    private let connection: NWConnection
    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: .main)
    }
    convenience init(port: UInt16) {
        self.init(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: Self.parameters()))
    }
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }
    func read(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }
    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    func close() { connection.cancel() }
}

/// Software memory/socket bound shared by every native radio owner in this app.
/// This is not a hardware data-path count or a claim that thirty radio peers work.
@MainActor
final class NearbyConnectionBudget {
    static let sharedApp = NearbyConnectionBudget()

    private enum Slot {
        case bootstrap
        case persistent(NearbyLaneRequest.Lane)
    }
    private var slots: [UUID: Slot] = [:]
    let persistentLimit: Int
    let bootstrapLimit: Int
    let perLaneLimit: Int

    init(persistentLimit: Int = SessionCapacityPolicy.listenerLimit * SessionCapacityPolicy.persistentLanesPerListener,
         bootstrapLimit: Int = SessionCapacityPolicy.transientAdmissionLimit,
         perLaneLimit: Int = SessionCapacityPolicy.listenerLimit) {
        precondition(persistentLimit > 0 && bootstrapLimit > 0 && perLaneLimit > 0)
        self.persistentLimit = persistentLimit
        self.bootstrapLimit = bootstrapLimit
        self.perLaneLimit = perLaneLimit
    }

    var connectionCount: Int { slots.count }
    var bootstrapCount: Int { slots.values.filter { if case .bootstrap = $0 { true } else { false } }.count }
    var persistentCount: Int { connectionCount - bootstrapCount }

    func acquireBootstrap() throws -> UUID {
        guard bootstrapCount < bootstrapLimit else { throw NearbyConnectionError.capacity }
        let lease = UUID()
        slots[lease] = .bootstrap
        return lease
    }

    func promote(_ lease: UUID, lane: NearbyLaneRequest.Lane) throws {
        guard let slot = slots[lease] else { throw NearbyConnectionError.closed }
        guard lane == .realtime || lane == .control || lane == .asset else { return }
        if case let .persistent(existing) = slot {
            guard existing == lane else { throw NearbyConnectionError.rejected }
            return
        }
        let laneCount = slots.values.filter {
            if case let .persistent(existing) = $0 { existing == lane } else { false }
        }.count
        guard persistentCount < persistentLimit, laneCount < perLaneLimit else { throw NearbyConnectionError.capacity }
        slots[lease] = .persistent(lane)
    }

    /// Tokens are never reused; repeated close/cancellation cannot release a newer owner.
    func release(_ lease: UUID) { slots.removeValue(forKey: lease) }
}

@MainActor
private final class NearbyMetadataLease {
    let budget: NearbyConnectionBudget
    let id: UUID
    var remote: (any NearbyByteConnection)?
    private(set) var ended = false
    init(budget: NearbyConnectionBudget) throws {
        self.budget = budget
        id = try budget.acquireBootstrap()
    }
    func close() {
        ended = true
        remote?.close(); remote = nil
        budget.release(id)
    }
}

/// One stream per lane prevents assets from sharing a userspace FIFO with realtime.
/// Each direction holds at most one 16 KiB chunk and waits for the downstream write.
/// Local sockets are adapters, never advertised addresses or evidence of a LAN route.
@MainActor
final class NearbySocketBridge {
    typealias Connect = @MainActor () async throws -> any NearbyByteConnection
    var onError: ((String) -> Void)?
    private var listeners: [NearbyOwnedListener] = []
    private var retiringListeners: [NearbyOwnedListener] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: [any NearbyByteConnection]] = [:]
    private var generation: UInt64 = 0
    private let budget: NearbyConnectionBudget
    private let localConnect: @MainActor (UInt16) -> any NearbyByteConnection
    private let guestPort: @MainActor (NearbyLaneRequest.Lane) -> UInt16?

    var guestAdaptersReady: Bool {
        listeners.count == 4 && listeners.allSatisfy {
            if case .ready = $0.listener.state { true } else { false }
        }
    }

    init(budget: NearbyConnectionBudget? = nil,
         guestPort: @escaping @MainActor (NearbyLaneRequest.Lane) -> UInt16? = { $0.localPort },
         localConnect: @escaping @MainActor (UInt16) -> any NearbyByteConnection = { NearbyTCPConnection(port: $0) }) {
        self.budget = budget ?? .sharedApp
        self.guestPort = guestPort
        self.localConnect = localConnect
    }

    func stop() {
        generation &+= 1
        retiringListeners.append(contentsOf: listeners); listeners.removeAll()
        retiringListeners.forEach { $0.listener.cancel() }
        connections.keys.forEach { budget.release($0) }
        connections.values.flatMap { $0 }.forEach { $0.close() }; connections.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
    }

    func accept(_ remote: any NearbyByteConnection, record: @escaping () -> BluetoothRoomRecord?) {
        let id: UUID
        do { id = try budget.acquireBootstrap() }
        catch { remote.close(); report(error); return }
        connections[id] = [remote]
        tasks[id] = Task { [weak self, budget] in
            guard let self else { remote.close(); budget.release(id); return }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                remote.close()
            }
            defer { deadline.cancel(); finish(id) }
            do {
                let request = try NearbyLaneRequest.decode(try await remote.readExactly(NearbyLaneRequest.size))
                guard !Task.isCancelled, connections[id] != nil else { throw CancellationError() }
                guard let current = record() else { throw NearbyConnectionError.rejected }
                if request.lane == .metadata {
                    let data = try current.encode()
                    try await remote.write(Data([UInt8(data.count >> 8), UInt8(data.count & 255)]) + data)
                    return
                }
                guard request.roomID == current.roomID, let port = request.lane.localPort else {
                    throw NearbyConnectionError.rejected
                }
                try budget.promote(id, lane: request.lane)
                let local = localConnect(port)
                connections[id]?.append(local)
                try await remote.write(Data([0]))
                deadline.cancel()
                let realtime = request.lane == .realtime
                let framed: any NearbyByteConnection = realtime ? NearbyRealtimeConnection(remote) : remote
                if realtime { connections[id]?.append(framed) }
                try await Self.pump(framed, local, realtime: realtime, drainAdmissionReply: request.lane == .admission)
            } catch {
                if !Task.isCancelled { report(error) }
            }
        }
    }

    static func readRecord(budget: NearbyConnectionBudget? = nil, connect: Connect) async throws -> BluetoothRoomRecord {
        let lease = try NearbyMetadataLease(budget: budget ?? .sharedApp)
        defer { lease.close() }
        return try await withTaskCancellationHandler {
            let remote = try await connect()
            guard !Task.isCancelled, !lease.ended else { remote.close(); throw CancellationError() }
            lease.remote = remote
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                lease.close()
            }
            defer { deadline.cancel() }
            try await remote.write(try NearbyLaneRequest(lane: .metadata, roomID: NearbyLaneRequest.metadataRoomID).encode())
            let prefix = [UInt8](try await remote.readExactly(2))
            let length = Int(prefix[0]) << 8 | Int(prefix[1])
            guard (40...439).contains(length) else { throw NearbyConnectionError.rejected }
            return try BluetoothRoomRecord.decode(try await remote.readExactly(length))
        } onCancel: {
            Task { @MainActor in lease.close() }
        }
    }

    func startGuest(roomID: UUID, connect: @escaping Connect) async throws -> String {
        stop()
        let attempt = generation
        do {
            // NWListener.cancel is asynchronous. Rebinding before its cancellation callback can
            // fail with EADDRINUSE even when no other tour owns these local adapter ports.
            for owner in retiringListeners { await owner.waitUntilCancelled() }
            retiringListeners.removeAll { $0.isCancelled }
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            for lane in NearbyLaneRequest.Lane.allCases where lane != .metadata {
                guard let port = guestPort(lane) else { throw NearbyConnectionError.rejected }
                let parameters = NearbyTCPConnection.parameters()
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                let owner = NearbyOwnedListener(listener)
                listener.newConnectionHandler = { [weak self] accepted in
                    let bridge = self
                    Task { @MainActor in
                        guard let bridge, bridge.generation == attempt else { accepted.cancel(); return }
                        bridge.attachGuest(NearbyTCPConnection(accepted), roomID: roomID, lane: lane, connect: connect)
                    }
                }
                listeners.append(owner)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let completion = NearbyListenerCompletion(continuation)
                    listener.stateUpdateHandler = { [weak owner] state in
                        Task { @MainActor [weak owner] in
                            switch state {
                            case .ready: completion.finish(.success(()))
                            case .failed(let error): completion.finish(.failure(error))
                            case .cancelled:
                                owner?.didCancel()
                                completion.finish(.failure(CancellationError()))
                            default: break
                            }
                        }
                    }
                    listener.start(queue: .main)
                }
                guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            }
            return "127.0.0.1"
        } catch {
            if generation == attempt { stop() }
            throw error
        }
    }

    private func attachGuest(_ local: any NearbyByteConnection, roomID: UUID,
                             lane: NearbyLaneRequest.Lane, connect: @escaping Connect) {
        let id: UUID
        do { id = try budget.acquireBootstrap() }
        catch { local.close(); report(error); return }
        connections[id] = [local]
        tasks[id] = Task { [weak self, budget] in
            guard let self else { local.close(); budget.release(id); return }
            defer { finish(id) }
            do {
                let remote = try await connect()
                guard !Task.isCancelled, connections[id] != nil else { remote.close(); return }
                connections[id]?.append(remote)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    remote.close()
                }
                defer { deadline.cancel() }
                try await remote.write(try NearbyLaneRequest(lane: lane, roomID: roomID).encode())
                guard try await remote.readExactly(1) == Data([0]) else { throw NearbyConnectionError.rejected }
                guard !Task.isCancelled, connections[id] != nil else { throw CancellationError() }
                try budget.promote(id, lane: lane)
                deadline.cancel()
                let realtime = lane == .realtime
                let framed: any NearbyByteConnection = realtime ? NearbyRealtimeConnection(remote) : remote
                if realtime { connections[id]?.append(framed) }
                try await Self.pump(local, framed, realtime: realtime)
            } catch { if !Task.isCancelled { report(error) } }
        }
    }

    private static func pump(_ first: any NearbyByteConnection, _ second: any NearbyByteConnection, realtime: Bool,
                             drainAdmissionReply: Bool = false) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { if realtime { try await copyRealtime(first, second) } else { try await copy(first, second) } }
            group.addTask {
                if realtime { try await copyRealtime(second, first) } else { try await copy(second, first) }
                // Native close may discard queued writes. Let the admitted guest receive
                // the final reply and close first; never retain an abandoned peer forever.
                if drainAdmissionReply {
                    try await Task.sleep(for: .seconds(5))
                    Logger.transport.warning("Admission reply drain deadline expired")
                }
            }
            do { _ = try await group.next() }
            catch { first.close(); second.close(); group.cancelAll(); throw error }
            first.close(); second.close(); group.cancelAll()
        }
    }

    private static func copyRealtime(_ source: any NearbyByteConnection, _ destination: any NearbyByteConnection) async throws {
        let queue = NearbyFramePipe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while !Task.isCancelled {
                        let prefix = try await source.readExactly(4)
                        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
                        guard (86...(NearbyRealtimeQueue.maximumFrameSize - 4)).contains(size) else {
                            throw NearbyConnectionError.rejected
                        }
                        let frame = try await source.readExactly(size)
                        try await queue.offer(prefix + frame, audio: realtimeFrameIsAudio(frame))
                    }
                    await queue.finish()
                } catch { await queue.finish(); throw error }
            }
            group.addTask {
                while let frame = await queue.next() {
                    let deadline = Task {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        await destination.close()
                    }
                    do { try await destination.write(frame); deadline.cancel() }
                    catch { deadline.cancel(); throw error }
                }
            }
            do { _ = try await group.next() }
            catch { source.close(); destination.close(); queue.finish(); group.cancelAll(); throw error }
            source.close(); destination.close(); queue.finish(); group.cancelAll()
        }
    }

    /// Structural classification only, never authentication. GOS1 adds an eight-byte wrapper
    /// before GOH2; inspecting byte seven would otherwise treat signed speech as reliable control.
    nonisolated static func realtimeFrameIsAudio(_ frame: Data) throws -> Bool {
        let sealed: Data
        if frame.prefix(4) == Data("GOS1".utf8) {
            guard (158...(SignedGuideFrame.maximumSealedSize + 72)).contains(frame.count) else {
                throw NearbyConnectionError.rejected
            }
            let length = frame.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard (86...SignedGuideFrame.maximumSealedSize).contains(Int(length)),
                  Int(length) == frame.count - 72 else { throw NearbyConnectionError.rejected }
            sealed = Data(frame.dropFirst(8).prefix(Int(length)))
        } else {
            sealed = frame
        }
        return try SealedSessionEnvelope.decode(sealed).kind == .audioFrame
    }

    private static func copy(_ source: any NearbyByteConnection, _ destination: any NearbyByteConnection) async throws {
        while !Task.isCancelled {
            let data = try await source.read(maximum: 16_384)
            if data.isEmpty { return }
            try await destination.write(data)
        }
    }

    private func finish(_ id: UUID) {
        budget.release(id)
        connections.removeValue(forKey: id)?.forEach { $0.close() }
        tasks.removeValue(forKey: id)
    }
    private func report(_ error: any Error) {
        Logger.transport.error("Nearby lane connection failed (\(String(describing: type(of: error))))")
        onError?(error.localizedDescription)
    }
}

@MainActor
private final class NearbyOwnedListener {
    let listener: NWListener
    private(set) var isCancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ listener: NWListener) { self.listener = listener }
    func waitUntilCancelled() async {
        guard !isCancelled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func didCancel() {
        isCancelled = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class NearbyFramePipe {
    private var backlog = NearbyRealtimeQueue()
    private var waiter: CheckedContinuation<Void, Never>?
    private var ended = false
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    func offer(_ bytes: Data, audio: Bool) throws {
        guard !ended else { throw NearbyConnectionError.closed }
        try backlog.offer(bytes, audio: audio, nowMilliseconds: now)
        wake()
    }
    func next() async -> Data? {
        while !Task.isCancelled {
            if let value = backlog.next(nowMilliseconds: now) { return value }
            if ended { return nil }
            await withCheckedContinuation { waiter = $0 }
        }
        return nil
    }
    func finish() { ended = true; wake() }
    private func wake() { let pending = waiter; waiter = nil; pending?.resume() }
}

@MainActor
private final class NearbyListenerCompletion {
    private var continuation: CheckedContinuation<Void, any Error>?
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, any Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
