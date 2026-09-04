import AVFoundation
import os

// Safe wrapper for passing AVAudioConverter through @Sendable boundaries.
// The audio tap runs on a single serial render thread, so this is safe.
struct AudioConverterRef: @unchecked Sendable {
    let converter: AVAudioConverter
}

enum AudioEngineError: LocalizedError {
    case captureUnavailable
    case audioSessionConfigurationFailed(String)
    case converterUnavailable
    case captureStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureUnavailable:
            "Microphone capture is unavailable in the iOS Simulator"
        case let .audioSessionConfigurationFailed(message):
            "Audio session configuration failed: \(message)"
        case .converterUnavailable:
            "The microphone format cannot be converted to tour audio"
        case let .captureStartFailed(message):
            "Microphone capture failed to start: \(message)"
        }
    }
}

@Observable
final class AudioEngine {
    private(set) var isCapturing = false
    private(set) var isPlaying = false

    /// Listener playback defaults to the receiver or connected headset so nearby
    /// speakers do not feed delayed tour audio back into the guide microphone.
    var listenerOutput: ListenerOutput = .privateAudio {
        didSet {
            if isPlaying { applyOutputRoute() }
        }
    }

    /// Noise gate threshold (RMS). Audio below this is suppressed.
    /// Suppresses low-level background noise. This is not echo cancellation.
    /// Range: 0.0 (disabled) to 1.0.
    /// Default is disabled to avoid dropping quiet speech during live chat.
    var noiseGateThreshold: Float = 0

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var hasCaptureTap = false
    private let continuationLock = OSAllocatedUnfairLock<AsyncStream<Data>.Continuation?>(initialState: nil)
    private var routeChangeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    // Canonical codec boundary: 16 kHz mono signed PCM16 little-endian.
    // Network transports encode this PCM before sending it.
    nonisolated static var wireFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }

    // MARK: - Capture

    func startCapture() throws -> AsyncStream<Data> {
#if targetEnvironment(simulator)
        Logger.audio.error("Microphone capture is unavailable in the iOS Simulator")
        throw AudioEngineError.captureUnavailable
#else
        stopCapture()

        try configureAudioSession(forCapture: true)
        logCurrentRoute("Capture")

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        enableVoiceProcessingIfSupported(on: inputNode)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        Logger.audio.info("Hardware input: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Convert hardware format → wire format
        guard let converter = AVAudioConverter(from: hwFormat, to: Self.wireFormat) else {
            Logger.audio.error("Failed to create converter: \(hwFormat) → \(Self.wireFormat)")
            engine.stop()
            self.engine = nil
            throw AudioEngineError.converterUnavailable
        }
        Logger.audio.info("Converter: \(hwFormat.sampleRate)Hz → \(Self.wireFormat.sampleRate)Hz")
        let converterRef = AudioConverterRef(converter: converter)
        let gateThreshold = noiseGateThreshold

        let stream = AsyncStream<Data> { [continuationLock] continuation in
            continuationLock.withLock { $0 = continuation }
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 345, // Requested ~7 ms at 48 kHz, but AVAudioEngine's input tap delivers ~100 ms buffers regardless (DSCN-5; LessonsLearned 58). The codec accumulator forms exact codec frames from whatever arrives.
            format: nil
        ) { @Sendable [converterRef, continuationLock] buffer, _ in
            // Noise gate: compute RMS and drop quiet buffers (echo, background noise)
            if gateThreshold > 0, let rms = AudioEngine.rms(of: buffer), rms < gateThreshold {
                return // Below threshold — suppress
            }

            let outputBuffer = AudioEngine.convert(buffer, using: converterRef.converter)
            guard let finalBuffer = outputBuffer,
                  let data = AudioEngine.bufferToData(finalBuffer) else { return }
            continuationLock.withLock { $0?.yield(data) }
        }
        hasCaptureTap = true

        observeRouteChanges()

        do {
            try engine.start()
            isCapturing = true
            Logger.audio.info("Capture engine started (noiseGate=\(gateThreshold))")
        } catch {
            cleanupCapturePipeline()
            Logger.audio.error("Capture engine failed to start")
            throw AudioEngineError.captureStartFailed(error.localizedDescription)
        }

        return stream
#endif
    }

    func stopCapture() {
        guard isCapturing || engine != nil else { return }
        cleanupCapturePipeline()
        Logger.audio.info("Capture stopped")
    }

    // MARK: - Playback

    func startPlayback() {
#if targetEnvironment(simulator)
        Logger.audio.error("Tour audio playback is unavailable in the iOS Simulator")
        return
#else
        stopPlayback()

        applyOutputRoute()
        logCurrentRoute("Playback")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.wireFormat)

        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.playerNode = player
            self.isPlaying = true
            Logger.audio.info("Playback started (output=\(self.listenerOutput.rawValue))")
        } catch {
            Logger.audio.error("Playback engine failed to start")
        }
#endif
    }

    func enqueuePlayback(_ data: Data) {
        guard let player = playerNode, let buffer = Self.dataToBuffer(data) else {
            Logger.audio.debug("Dropped audio packet: \(data.count) bytes")
            return
        }
        player.scheduleBuffer(buffer)
    }

    func stopPlayback() {
        guard isPlaying else { return }
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        isPlaying = false
        removeObservers()
        Logger.audio.info("Playback stopped")
    }

    // MARK: - Audio Session & Routing

    private func configureAudioSession(forCapture: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // Deactivate first to cleanly switch categories
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            if forCapture {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            }
            try session.setActive(true)
            Logger.audio.info("Session: capture=\(forCapture), rate=\(session.sampleRate)Hz")
        } catch {
            Logger.audio.error("Audio session config failed")
            throw AudioEngineError.audioSessionConfigurationFailed(error.localizedDescription)
        }
    }

    private func cleanupCapturePipeline() {
        if hasCaptureTap {
            engine?.inputNode.removeTap(onBus: 0)
            hasCaptureTap = false
        }
        engine?.stop()
        engine = nil
        isCapturing = false
        removeObservers()
        continuationLock.withLock {
            $0?.finish()
            $0 = nil
        }
    }

    private func applyOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        do {
            if listenerOutput == .privateAudio {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
                try session.overrideOutputAudioPort(.none)
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP])
            }
            try session.setActive(true)
            Logger.audio.info("Output route: \(self.listenerOutput.rawValue)")
        } catch {
            Logger.audio.error("Output route override failed")
        }
    }

    private func enableVoiceProcessingIfSupported(on inputNode: AVAudioInputNode) {
        let usesBluetoothHFP = AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.portType == .bluetoothHFP
        }
        guard !usesBluetoothHFP else {
            Logger.audio.info("Voice processing skipped for Bluetooth HFP route")
            return
        }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            Logger.audio.info("Voice processing enabled")
        } catch {
            Logger.audio.error("Voice processing unavailable")
        }
    }

    private func logCurrentRoute(_ context: String) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: ", ")
        let outputs = route.outputs.map(\.portType.rawValue).joined(separator: ", ")
        Logger.audio.info("[\(context)] Route — in: [\(inputs)], out: [\(outputs)]")
    }

    // MARK: - Route Change Handling

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            Logger.audio.info("Route changed: reason=\(reason?.rawValue ?? 999)")
            self.logCurrentRoute("RouteChange")
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.audio.warning("Engine config changed — hardware format may have shifted")
            if let engine = self.engine {
                let newFormat = engine.inputNode.outputFormat(forBus: 0)
                Logger.audio.info("New input format: \(newFormat.sampleRate)Hz, \(newFormat.channelCount)ch")
            }
        }
    }

    private func removeObservers() {
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
    }

    // MARK: - Noise Gate (Voice Activity Detection lite)

    /// Compute RMS of the buffer's first channel. Returns nil if no float data.
    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        var sum: Float = 0
        let ptr = channelData[0]
        for i in 0..<frameLength {
            let sample = ptr[i]
            sum += sample * sample
        }
        return sqrtf(sum / Float(frameLength))
    }

    // MARK: - Format Conversion

    nonisolated private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = wireFormat.sampleRate / input.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio))
        guard outputCapacity > 0 else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outputCapacity) else { return nil }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if error != nil { return nil }
        guard status != .error else { return nil }
        return output
    }

    // MARK: - Serialization (PCM16 mono)

    nonisolated private static func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    nonisolated private static func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }
        let format = wireFormat
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            memcpy(destination, source, data.count)
            buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(data.count)
        }
        return buffer
    }
}
