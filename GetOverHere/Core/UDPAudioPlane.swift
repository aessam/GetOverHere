import Foundation
import Darwin
import os

/// TCP-based audio transport for cross-platform audio over WiFi hotspot.
///
/// Broadcasting (sender): Starts TCP server on port 50000, clients connect.
/// Listening (receiver): Connects to sender's TCP server via hostIP.
///
/// TCP avoids all the UDP broadcast interface routing issues on Android hotspot.
@Observable
final class UDPAudioPlane: AudioPlane {
    private(set) var isActive = false

    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var connectedClients: [Int32] = []
    private var sendQueue = DispatchQueue(label: "audio.tcp.send", qos: .userInteractive)
    private var recvTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    nonisolated(unsafe) private var onAudioCallback: (@Sendable (Data) -> Void)?

    /// Set by NetworkCoordinator — the Android hotspot IP for TCP connection
    var hostIP: String?

    private let port: UInt16 = 50000

    // MARK: - Sender (TCP Server)

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { Logger.audio.error("TCP: socket failed"); return }

        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { Logger.audio.error("TCP: bind failed: \(String(cString: strerror(errno)))"); return }

        listen(serverFD, 10)
        isActive = true
        Logger.audio.info("TCP: server listening on port \(self.port)")

        // Accept loop
        let fd = serverFD
        acceptTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                var clientAddr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
                }
                guard clientFD >= 0 else { break }
                await MainActor.run {
                    self?.connectedClients.append(clientFD)
                    Logger.audio.info("TCP: client connected (fd=\(clientFD))")
                }
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard isActive, !connectedClients.isEmpty else { return }
        sendQueue.async { [weak self] in
            guard let self else { return }
            // Length-prefixed: [4 bytes big-endian length][data]
            var len = UInt32(data.count).bigEndian
            let header = Data(bytes: &len, count: 4)
            var dead: [Int32] = []
            for fd in self.connectedClients {
                header.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    if Darwin.send(fd, base, 4, MSG_NOSIGNAL) < 0 { dead.append(fd) }
                }
                data.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    if Darwin.send(fd, base, data.count, MSG_NOSIGNAL) < 0 { dead.append(fd) }
                }
            }
            if !dead.isEmpty {
                Task { @MainActor [weak self] in
                    self?.connectedClients.removeAll { dead.contains($0) }
                    dead.forEach { close($0) }
                }
            }
        }
    }

    // MARK: - Listener (TCP Client)

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        self.onAudioCallback = onAudio
        guard let host = hostIP else {
            Logger.audio.error("TCP: no hostIP to connect to")
            return
        }

        isActive = true
        recvTask = Task.detached { [weak self] in
            Logger.audio.info("TCP: connecting to \(host):\(self?.port ?? 0)")
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { Logger.audio.error("TCP: socket failed"); return }

            await MainActor.run { self?.clientFD = fd }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = (self?.port ?? 50000).bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connectResult == 0 else {
                Logger.audio.error("TCP: connect failed: \(String(cString: strerror(errno)))")
                return
            }
            Logger.audio.info("TCP: connected to server")

            // Read loop: [4 bytes length][data]
            var headerBuf = [UInt8](repeating: 0, count: 4)
            while !Task.isCancelled {
                guard Self.readExact(fd: fd, buf: &headerBuf, count: 4) else { break }
                let len = Int(UInt32(bigEndian: headerBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
                guard len > 0, len < 65536 else { continue }

                var dataBuf = [UInt8](repeating: 0, count: len)
                guard Self.readExact(fd: fd, buf: &dataBuf, count: len) else { break }

                let data = Data(dataBuf)
                self?.onAudioCallback?(data)
            }
            Logger.audio.info("TCP: disconnected")
        }
    }

    func stop() {
        isActive = false
        acceptTask?.cancel(); recvTask?.cancel()
        acceptTask = nil; recvTask = nil
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        connectedClients.forEach { close($0) }
        connectedClients.removeAll()
        onAudioCallback = nil
        Logger.audio.info("TCP: stopped")
    }

    // MARK: - Helpers

    nonisolated private static func readExact(fd: Int32, buf: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = recv(fd, &buf[offset], count - offset, 0)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
