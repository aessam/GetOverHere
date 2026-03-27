import Foundation
import Network
import os

/// UDP broadcast audio transport for cross-platform audio over WiFi hotspot.
/// Uses broadcast instead of multicast (Android's local-only hotspot doesn't support multicast).
///
/// Port: 50000
/// Packet format: raw float32 PCM audio
@Observable
final class UDPAudioPlane: AudioPlane {
    private(set) var isActive = false

    private var connection: NWConnection?
    private var listener: NWListener?
    nonisolated(unsafe) private var onAudioCallback: (@Sendable (Data) -> Void)?

    private let port: UInt16 = 50000

    // MARK: - AudioPlane

    func startBroadcasting(channelID: String, quality: AudioQuality) {
        // UDP broadcast to 255.255.255.255
        let host = NWEndpoint.Host("255.255.255.255")
        let port = NWEndpoint.Port(rawValue: self.port)!

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi

        connection = NWConnection(host: host, port: port, using: params)
        connection?.start(queue: .global(qos: .userInteractive))
        isActive = true
        Logger.audio.info("UDP: broadcasting on port \(self.port) (broadcast)")
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

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInteractive))
                self?.receiveLoop(conn)
            }
            listener?.start(queue: .global(qos: .userInteractive))
            isActive = true
            Logger.audio.info("UDP: listening on port \(self.port) (broadcast)")
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

    // MARK: - Receive

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.onAudioCallback?(data)
            }
            if error == nil, self?.isActive == true {
                self?.receiveLoop(connection)
            }
        }
    }
}
