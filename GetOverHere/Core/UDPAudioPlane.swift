import Foundation
import Darwin
import os

/// UDP broadcast audio transport using BSD sockets (reliable for broadcast).
/// NWListener doesn't properly handle broadcast datagrams — BSD sockets do.
///
/// Port: 50000, Address: 255.255.255.255 (broadcast)
@Observable
final class UDPAudioPlane: AudioPlane {
    private(set) var isActive = false

    private var sendSocket: Int32 = -1
    private var recvSocket: Int32 = -1
    private var recvTask: Task<Void, Never>?
    nonisolated(unsafe) private var onAudioCallback: (@Sendable (Data) -> Void)?

    private let port: UInt16 = 50000

    // MARK: - AudioPlane

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        sendSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard sendSocket >= 0 else {
            Logger.audio.error("UDP: failed to create send socket")
            return
        }
        var yes: Int32 = 1
        setsockopt(sendSocket, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        isActive = true
        Logger.audio.info("UDP: broadcasting on port \(self.port) (BSD socket)")
    }

    func sendAudio(_ data: Data) {
        guard isActive, sendSocket >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST

        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                    Darwin.sendto(sendSocket, ptr, data.count, 0, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        self.onAudioCallback = onAudio

        recvSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard recvSocket >= 0 else {
            Logger.audio.error("UDP: failed to create recv socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(recvSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(recvSocket, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(recvSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Logger.audio.error("UDP: bind failed: \(String(cString: strerror(errno)))")
            return
        }

        isActive = true
        Logger.audio.info("UDP: listening on port \(self.port) (BSD socket)")

        // Receive loop on background thread
        let sock = recvSocket
        recvTask = Task.detached { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    self?.onAudioCallback?(data)
                } else if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
            }
        }
    }

    func stop() {
        isActive = false
        recvTask?.cancel()
        recvTask = nil
        if sendSocket >= 0 { close(sendSocket); sendSocket = -1 }
        if recvSocket >= 0 { close(recvSocket); recvSocket = -1 }
        onAudioCallback = nil
        Logger.audio.info("UDP: stopped")
    }
}
