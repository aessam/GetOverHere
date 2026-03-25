import Foundation
import Network
import os

/// UDP multicast audio transport for cross-platform audio over WiFi hotspot.
/// Uses Apple's Network framework (NWConnection / NWListener).
///
/// Multicast group: 239.0.0.1, port: 50000
/// Packet format: raw float32 PCM audio (no headers — channelID filtering happens at service layer)
@Observable
final class UDPAudioPlane: AudioPlane {
    private(set) var isActive = false

    private var connection: NWConnection?
    private var listener: NWListener?
    private var group: NWMulticastGroup?
    nonisolated(unsafe) private var onAudioCallback: (@Sendable (Data) -> Void)?

    private let multicastHost = "239.0.0.1"
    private let multicastPort: UInt16 = 50000

    // MARK: - AudioPlane

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        let host = NWEndpoint.Host(multicastHost)
        let port = NWEndpoint.Port(rawValue: multicastPort)!

        connection = NWConnection(host: host, port: port, using: .udp)
        connection?.start(queue: .global(qos: .userInteractive))
        isActive = true
        Logger.audio.info("UDP: broadcasting on \(self.multicastHost):\(self.multicastPort)")
    }

    func sendAudio(_ data: Data) {
        guard let connection, isActive else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func startListening(channelID: String, onAudio: @escaping @Sendable (Data) -> Void) {
        self.onAudioCallback = onAudio

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .wifi

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: multicastPort)!)
            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInteractive))
                self?.receiveLoop(connection)
            }
            listener?.start(queue: .global(qos: .userInteractive))
            isActive = true
            Logger.audio.info("UDP: listening on port \(self.multicastPort)")

            // Also set up multicast receive
            setupMulticastReceive()
        } catch {
            Logger.audio.error("UDP listener failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        onAudioCallback = nil
        isActive = false
        Logger.audio.info("UDP: stopped")
    }

    // MARK: - Multicast Receive

    private func setupMulticastReceive() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let host = NWEndpoint.Host(multicastHost)
        let port = NWEndpoint.Port(rawValue: multicastPort)!

        let conn = NWConnection(host: host, port: port, using: params)
        conn.start(queue: .global(qos: .userInteractive))
        self.connection = conn
        receiveLoop(conn)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.onAudioCallback?(data)
            }
            if error == nil {
                self?.receiveLoop(connection) // Continue receiving
            }
        }
    }
}
