import CoreBluetooth
import Foundation
import os

/// L2CAP-based audio streaming for cross-platform BLE audio.
/// GATT handles discovery/metadata. L2CAP handles the audio pipe.
///
/// Creator (speaker): publishes L2CAP channel, writes audio to all connected channels.
/// Listener: connects to creator's L2CAP PSM, reads audio from stream.
@Observable
final class L2CAPAudioStream: NSObject {
    /// The PSM number assigned by the system when publishing. Listeners read this via GATT.
    private(set) var publishedPSM: UInt16 = 0

    /// Active L2CAP channels (both incoming and outgoing)
    private var channels: [CBL2CAPChannel] = []
    private var peripheralManager: CBPeripheralManager?
    private var readTask: Task<Void, Never>?

    /// Called when audio data is received from a remote speaker
    var onAudioReceived: ((Data) -> Void)?

    // MARK: - Publisher (Creator/Speaker side)

    /// Start publishing an L2CAP channel. The system assigns a PSM.
    /// Call this when creating a megaphone channel.
    func startPublishing(peripheralManager: CBPeripheralManager) {
        self.peripheralManager = peripheralManager
        peripheralManager.publishL2CAPChannel(withEncryption: false)
        Logger.audio.info("L2CAP: publishing channel...")
    }

    /// Stop publishing and close all channels.
    func stopPublishing() {
        if publishedPSM != 0 {
            peripheralManager?.unpublishL2CAPChannel(publishedPSM)
        }
        closeAllChannels()
        publishedPSM = 0
        Logger.audio.info("L2CAP: stopped publishing")
    }

    /// Write audio data to ALL connected L2CAP channels.
    func writeAudio(_ data: Data) {
        for channel in channels {
            guard let stream = channel.outputStream else { continue }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                stream.write(ptr, maxLength: data.count)
            }
        }
    }

    // MARK: - Subscriber (Listener side)

    /// Connect to a remote device's L2CAP channel using the PSM from GATT.
    func connectToChannel(on peripheral: CBPeripheral, psm: UInt16) {
        peripheral.openL2CAPChannel(psm)
        Logger.audio.info("L2CAP: opening channel to \(peripheral.identifier.uuidString.prefix(8)) PSM=\(psm)")
    }

    /// Stop listening and close all channels.
    func stopListening() {
        readTask?.cancel()
        readTask = nil
        closeAllChannels()
        Logger.audio.info("L2CAP: stopped listening")
    }

    // MARK: - Channel Management

    /// Called by BLETransport when a new L2CAP channel opens (both publisher and subscriber).
    func handleChannelOpened(_ channel: CBL2CAPChannel) {
        channels.append(channel)
        Logger.audio.info("L2CAP: channel opened (PSM=\(channel.psm), total=\(self.channels.count))")

        // Start reading from this channel's input stream
        if let inputStream = channel.inputStream {
            startReading(from: inputStream)
        }
    }

    private func startReading(from stream: InputStream) {
        stream.open()
        readTask = Task { [weak self] in
            let bufferSize = 2048
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while !Task.isCancelled {
                guard stream.hasBytesAvailable else {
                    try? await Task.sleep(for: .milliseconds(5))
                    continue
                }
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    await MainActor.run { [weak self] in
                        self?.onAudioReceived?(data)
                    }
                } else if bytesRead < 0 {
                    Logger.audio.error("L2CAP: read error")
                    break
                }
            }
        }
    }

    private func closeAllChannels() {
        for channel in channels {
            channel.inputStream?.close()
            channel.outputStream?.close()
        }
        channels.removeAll()
    }

    // MARK: - CBPeripheralManager Delegate Hooks (called from BLETransport)

    /// Called when L2CAP channel is published. Stores the PSM.
    func didPublishL2CAPChannel(psm: UInt16, error: Error?) {
        if let error {
            Logger.audio.error("L2CAP: publish failed: \(error.localizedDescription)")
            return
        }
        publishedPSM = psm
        Logger.audio.info("L2CAP: published with PSM=\(psm)")
    }
}
