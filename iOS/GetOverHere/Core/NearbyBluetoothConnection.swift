import CoreBluetooth
import Foundation

/// Core Bluetooth owns the LE credit-based stream. One outstanding read and write;
/// no polling, spin loop, unbounded FIFO, or invented IP address for the peer.
@MainActor
final class NearbyBluetoothConnection: NSObject, NearbyByteConnection, StreamDelegate {
    private let channel: CBL2CAPChannel
    private var closed = false
    private var reader: CheckedContinuation<Data, any Error>?
    private var readMaximum = 0
    private var writer: CheckedContinuation<Void, any Error>?
    private var output = Data()
    private var outputOffset = 0

    init(_ channel: CBL2CAPChannel) {
        self.channel = channel
        super.init()
        channel.inputStream.delegate = self; channel.outputStream.delegate = self
        channel.inputStream.schedule(in: .main, forMode: .common)
        channel.outputStream.schedule(in: .main, forMode: .common)
        channel.inputStream.open(); channel.outputStream.open()
    }

    func read(maximum: Int) async throws -> Data {
        guard !closed else { throw NearbyConnectionError.closed }
        precondition(reader == nil && (1...16_384).contains(maximum))
        return try await withCheckedThrowingContinuation { continuation in
            reader = continuation; readMaximum = maximum; receiveAvailable()
        }
    }
    func write(_ bytes: Data) async throws {
        guard !closed else { throw NearbyConnectionError.closed }
        precondition(writer == nil && bytes.count <= 16_384)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer = continuation; output = bytes; outputOffset = 0; sendAvailable()
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        channel.inputStream.delegate = nil; channel.outputStream.delegate = nil
        channel.inputStream.remove(from: .main, forMode: .common)
        channel.outputStream.remove(from: .main, forMode: .common)
        channel.inputStream.close(); channel.outputStream.close()
        let pendingReader = reader; reader = nil
        let pendingWriter = writer; writer = nil
        output = Data()
        pendingReader?.resume(throwing: NearbyConnectionError.closed)
        pendingWriter?.resume(throwing: NearbyConnectionError.closed)
    }
    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { close(); return }
            receiveAvailable(); sendAvailable()
        }
    }
    private func receiveAvailable() {
        guard !closed, let continuation = reader, channel.inputStream.hasBytesAvailable else { return }
        var bytes = [UInt8](repeating: 0, count: readMaximum)
        let count = channel.inputStream.read(&bytes, maxLength: bytes.count)
        if count < 0 { close(); return }
        reader = nil
        continuation.resume(returning: Data(bytes.prefix(count)))
    }
    private func sendAvailable() {
        guard !closed, let continuation = writer else { return }
        while outputOffset < output.count && channel.outputStream.hasSpaceAvailable {
            let count = output.withUnsafeBytes { buffer -> Int in
                guard let start = buffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return channel.outputStream.write(start.advanced(by: outputOffset), maxLength: output.count - outputOffset)
            }
            if count < 0 { close(); return }
            if count == 0 { return }
            outputOffset += count
        }
        if outputOffset == output.count {
            writer = nil; output = Data(); outputOffset = 0
            continuation.resume()
        }
    }
}
