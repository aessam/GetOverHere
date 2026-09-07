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

/// One stream per lane prevents assets from sharing a userspace FIFO with realtime.
/// Each direction holds at most one 16 KiB chunk and waits for the downstream write.
/// Local sockets are adapters, never advertised addresses or evidence of a LAN route.
@MainActor
final class NearbySocketBridge {
    typealias Connect = @MainActor () async throws -> any NearbyByteConnection
    var onError: ((String) -> Void)?
    private var listeners: [NWListener] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: [any NearbyByteConnection]] = [:]
    private var generation: UInt64 = 0
    private let maximumConnections: Int
    private let localConnect: @MainActor (UInt16) -> any NearbyByteConnection

    init(maximumConnections: Int = 32,
         localConnect: @escaping @MainActor (UInt16) -> any NearbyByteConnection = { NearbyTCPConnection(port: $0) }) {
        precondition(maximumConnections > 0)
        self.maximumConnections = maximumConnections
        self.localConnect = localConnect
    }

    func stop() {
        generation &+= 1
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        connections.values.flatMap { $0 }.forEach { $0.close() }; connections.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
    }

    func accept(_ remote: any NearbyByteConnection, record: @escaping () -> BluetoothRoomRecord?) {
        guard tasks.count < maximumConnections else { remote.close(); report(NearbyConnectionError.capacity); return }
        let id = UUID()
        connections[id] = [remote]
        tasks[id] = Task { [weak self] in
            guard let self else { remote.close(); return }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                remote.close()
            }
            defer { deadline.cancel(); finish(id) }
            do {
                let request = try NearbyLaneRequest.decode(try await remote.readExactly(NearbyLaneRequest.size))
                guard let current = record() else { throw NearbyConnectionError.rejected }
                if request.lane == .metadata {
                    let data = try current.encode()
                    try await remote.write(Data([UInt8(data.count >> 8), UInt8(data.count & 255)]) + data)
                    return
                }
                guard request.roomID == current.roomID, let port = request.lane.localPort else {
                    throw NearbyConnectionError.rejected
                }
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

    static func readRecord(connect: Connect) async throws -> BluetoothRoomRecord {
        let remote = try await connect()
        defer { remote.close() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            remote.close()
        }
        defer { deadline.cancel() }
        try await remote.write(try NearbyLaneRequest(lane: .metadata, roomID: NearbyLaneRequest.metadataRoomID).encode())
        let prefix = [UInt8](try await remote.readExactly(2))
        let length = Int(prefix[0]) << 8 | Int(prefix[1])
        guard (40...439).contains(length) else { throw NearbyConnectionError.rejected }
        return try BluetoothRoomRecord.decode(try await remote.readExactly(length))
    }

    func startGuest(roomID: UUID, connect: @escaping Connect) async throws -> String {
        stop()
        let attempt = generation
        do {
            for lane in NearbyLaneRequest.Lane.allCases where lane != .metadata {
                guard let port = lane.localPort else { throw NearbyConnectionError.rejected }
                let parameters = NearbyTCPConnection.parameters()
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] accepted in
                    let bridge = self
                    Task { @MainActor in
                        guard let bridge, bridge.generation == attempt else { accepted.cancel(); return }
                        bridge.attachGuest(NearbyTCPConnection(accepted), roomID: roomID, lane: lane, connect: connect)
                    }
                }
                listeners.append(listener)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let completion = NearbyListenerCompletion(continuation)
                    listener.stateUpdateHandler = { state in
                        Task { @MainActor in
                            switch state {
                            case .ready: completion.finish(.success(()))
                            case .failed(let error): completion.finish(.failure(error))
                            case .cancelled: completion.finish(.failure(CancellationError()))
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
        guard tasks.count < maximumConnections else { local.close(); report(NearbyConnectionError.capacity); return }
        let id = UUID()
        connections[id] = [local]
        tasks[id] = Task { [weak self] in
            guard let self else { local.close(); return }
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
                        guard (70...(NearbyRealtimeQueue.maximumFrameSize - 4)).contains(size) else {
                            throw NearbyConnectionError.rejected
                        }
                        let frame = try await source.readExactly(size)
                        // Only inspect the public kind byte. Authentication remains at the receiving lane.
                        try await queue.offer(prefix + frame, audio: frame[7] == 0x10)
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

    private static func copy(_ source: any NearbyByteConnection, _ destination: any NearbyByteConnection) async throws {
        while !Task.isCancelled {
            let data = try await source.read(maximum: 16_384)
            if data.isEmpty { return }
            try await destination.write(data)
        }
    }

    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.forEach { $0.close() }
        tasks.removeValue(forKey: id)
    }
    private func report(_ error: any Error) {
        Logger.transport.error("Nearby lane connection failed (\(String(describing: type(of: error))))")
        onError?(error.localizedDescription)
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
