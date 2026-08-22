import AVFoundation
import os

// Safe wrapper for passing AVAudioConverter through @Sendable boundaries.
// The audio tap runs on a single serial render thread, so this is safe.
struct AudioConverterRef: @unchecked Sendable {
    let converter: AVAudioConverter?
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
    private let continuationLock = OSAllocatedUnfairLock<AsyncStream<Data>.Continuation?>(initialState: nil)
    private var routeChangeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    // Canonical wire format — all audio is normalized to this before sending.
    // 16kHz mono float32: good for voice, ~64 KB/s, works regardless of
    // whether sender/receiver uses AirPods, speaker, or any other hardware.
    nonisolated static var wireFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Capture

    func startCapture() -> AsyncStream<Data> {
#if targetEnvironment(simulator)
        Logger.audio.error("Microphone capture is unavailable in the iOS Simulator")
        return AsyncStream { continuation in
            continuation.finish()
        }
#else
        stopCapture()

        configureAudioSession(forCapture: true)
        logCurrentRoute("Capture")

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        enableVoiceProcessingIfSupported(on: inputNode)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        Logger.audio.info("Hardware input: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Convert hardware format → wire format
        let converter = AVAudioConverter(from: hwFormat, to: Self.wireFormat)
        if converter == nil {
            Logger.audio.error("Failed to create converter: \(hwFormat) → \(Self.wireFormat)")
        } else {
            Logger.audio.info("Converter: \(hwFormat.sampleRate)Hz → \(Self.wireFormat.sampleRate)Hz")
        }
        let converterRef = AudioConverterRef(converter: converter)
        let gateThreshold = noiseGateThreshold

        let stream = AsyncStream<Data> { [continuationLock] continuation in
            continuationLock.withLock { $0 = continuation }
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 345, // ~7ms at 48kHz → ~115 frames at 16kHz → ~460 bytes (fits in one BLE MTU)
            format: nil
        ) { @Sendable [converterRef, continuationLock] buffer, _ in
            // Noise gate: compute RMS and drop quiet buffers (echo, background noise)
            if gateThreshold > 0, let rms = AudioEngine.rms(of: buffer), rms < gateThreshold {
                return // Below threshold — suppress
            }

            let outputBuffer: AVAudioPCMBuffer?
            if let conv = converterRef.converter {
                outputBuffer = AudioEngine.convert(buffer, using: conv)
            } else {
                outputBuffer = buffer
            }
            guard let finalBuffer = outputBuffer,
                  let data = AudioEngine.bufferToData(finalBuffer) else { return }
            continuationLock.withLock { $0?.yield(data) }
        }

        observeRouteChanges()

        do {
            try engine.start()
            isCapturing = true
            Logger.audio.info("Capture engine started (noiseGate=\(gateThreshold))")
        } catch {
            Logger.audio.error("Capture engine failed to start")
        }

        return stream
#endif
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isCapturing = false
        removeObservers()
        continuationLock.withLock {
            $0?.finish()
            $0 = nil
        }
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

    private func configureAudioSession(forCapture: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            // Deactivate first to cleanly switch categories
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if forCapture {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            }
            try session.setActive(true)
            Logger.audio.info("Session: capture=\(forCapture), rate=\(session.sampleRate)Hz")
        } catch {
            Logger.audio.error("Audio session config failed")
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

    // MARK: - Serialization (float32 mono)

    nonisolated private static func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Data(bytes: channelData[0], count: frameLength * MemoryLayout<Float>.size)
    }

    nonisolated private static func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let format = wireFormat
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Float>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            memcpy(buffer.floatChannelData![0], source, data.count)
        }
        return buffer
    }
}
