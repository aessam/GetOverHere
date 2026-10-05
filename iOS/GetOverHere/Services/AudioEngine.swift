import AVFoundation
import os

// Safe wrapper for passing AVAudioConverter through @Sendable boundaries.
// The audio tap runs on a single serial render thread, so this is safe.
struct AudioConverterRef: @unchecked Sendable {
    let converter: AVAudioConverter
}

enum AudioEngineError: LocalizedError {
    case captureUnavailable
    case playbackUnavailable
    case audioSessionConfigurationFailed(String)
    case converterUnavailable
    case captureStartFailed(String)
    case playbackStartFailed(String)
    case audioRuntimeResumeFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureUnavailable:
            "Microphone capture is unavailable in the iOS Simulator"
        case .playbackUnavailable:
            "Tour audio playback is unavailable in the iOS Simulator"
        case let .audioSessionConfigurationFailed(message):
            "Audio session configuration failed: \(message)"
        case .converterUnavailable:
            "The microphone format cannot be converted to tour audio"
        case let .captureStartFailed(message):
            "Microphone capture failed to start: \(message)"
        case let .playbackStartFailed(message):
            "Tour audio playback failed to start: \(message)"
        case let .audioRuntimeResumeFailed(message):
            "Tour audio could not resume: \(message)"
        }
    }
}

/// Bounds renderer latency (FND-10). Frames delayed by a main-thread stall arrive together; past the
/// limit the queued audio is flushed instead of permanently delaying live speech by the stall length.
nonisolated final class PlaybackBacklog: Sendable {
    enum Admission: Equatable {
        case schedule(generation: UInt64)
        case flushThenSchedule(generation: UInt64)
    }

    /// About 200 ms of 20 ms frames.
    static let maximumQueuedBuffers = 10

    private struct State {
        var generation: UInt64 = 0
        var queued = 0
        var flushes: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var queuedBufferCount: Int { state.withLock { $0.queued } }
    var flushCount: UInt64 { state.withLock { $0.flushes } }

    func admit() -> Admission {
        state.withLock { state in
            if state.queued >= Self.maximumQueuedBuffers {
                state.generation &+= 1
                state.queued = 1
                state.flushes &+= 1
                return .flushThenSchedule(generation: state.generation)
            }
            state.queued += 1
            return .schedule(generation: state.generation)
        }
    }

    /// Completions from flushed or stopped generations are ignored.
    func completed(generation: UInt64) {
        state.withLock { state in
            if state.generation == generation, state.queued > 0 { state.queued -= 1 }
        }
    }

    func reset() {
        state.withLock { state in
            state.generation &+= 1
            state.queued = 0
        }
    }
}

/// Test seam (DSCN-23): the production engine needs real audio hardware, and simulator capture
/// throws by design. No behavior change.
protocol AudioEngineInterface: AnyObject {
    var listenerOutput: ListenerOutput { get set }
    var isCapturing: Bool { get }
    var isPlaying: Bool { get }
    var onRuntimeEvent: ((AudioRuntimeEvent) -> Void)? { get set }
    func startCapture() throws -> AsyncStream<Data>
    func stopCapture()
    func startPlayback() throws
    func enqueuePlayback(_ data: Data)
    func stopPlayback()
}

nonisolated enum AudioRuntimeRole: Equatable, Sendable {
    case capture
    case playback
}

nonisolated enum AudioRuntimeEvent: Equatable, Sendable {
    case started(AudioRuntimeRole)
    case interrupted(AudioRuntimeRole)
    case resumed(AudioRuntimeRole)
    case failed(AudioRuntimeRole, String)
    /// The renderer accepted valid decoded PCM. This does not assert acoustic output.
    case firstPlaybackBufferAccepted
}

/// Hardware boundary used to exercise lifecycle failures without pretending that simulator
/// playback is supported. The default implementation always uses the native audio engine.
protocol AudioPlaybackRuntimeInterface: AnyObject {
    var configurationChangeSource: AnyObject? { get }
    func start(output: ListenerOutput) throws
    func updateOutput(_ output: ListenerOutput) throws
    func pause()
    func resume(output: ListenerOutput) throws
    func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool
    func stop()
}

private final class NativeAudioPlaybackRuntime: AudioPlaybackRuntimeInterface {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var ownsAudioSession = false
    private let backlog = PlaybackBacklog()

    var configurationChangeSource: AnyObject? { engine }

    func start(output: ListenerOutput) throws {
#if targetEnvironment(simulator)
        throw AudioEngineError.playbackUnavailable
#else
        try updateOutput(output)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.engine = engine
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AudioEngine.wireFormat)
        try engine.start()
        player.play()
#endif
    }

    func updateOutput(_ output: ListenerOutput) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            if output == .privateAudio {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
                try session.overrideOutputAudioPort(.none)
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP])
            }
            try session.setActive(true)
            ownsAudioSession = true
        } catch {
            throw AudioEngineError.audioSessionConfigurationFailed(error.localizedDescription)
        }
    }

    func pause() {
        // Stop (rather than pause) the player to discard queued speech during an interruption.
        player?.stop()
        backlog.reset()
        engine?.pause()
    }

    func resume(output: ListenerOutput) throws {
        guard let engine, let player else {
            throw AudioEngineError.audioRuntimeResumeFailed("Playback resources are unavailable")
        }
        try updateOutput(output)
        player.stop()
        backlog.reset()
        engine.stop()
        engine.connect(player, to: engine.mainMixerNode, format: AudioEngine.wireFormat)
        try engine.start()
        player.play()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let engine, engine.isRunning, let player, player.isPlaying else { return false }
        let generation: UInt64
        switch backlog.admit() {
        case let .schedule(current):
            generation = current
        case let .flushThenSchedule(current):
            generation = current
            player.stop()
            player.play()
            Logger.audio.warning("Playback backlog exceeded \(PlaybackBacklog.maximumQueuedBuffers) buffers; flushed (\(self.backlog.flushCount) total)")
        }
        player.scheduleBuffer(buffer) { [backlog] in backlog.completed(generation: generation) }
        return true
    }

    func stop() {
        player?.stop()
        backlog.reset()
        engine?.stop()
        player = nil
        engine = nil
        if ownsAudioSession {
            ownsAudioSession = false
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Logger.audio.error("Playback session deactivation failed (\(String(describing: type(of: error))))")
            }
        }
    }
}

/// What the capture pipeline does in response to an `AVAudioSession` interruption (FND-13).
nonisolated enum CaptureInterruptionAction: Equatable, Sendable {
    case pause
    case resume
    case stop
    case ignore
}

/// The tap owns this run's bounded continuation. A late tap can never publish into a new run.
nonisolated final class AudioCaptureStream: Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let drops = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var droppedBufferCount: UInt64 { drops.withLock { $0 } }

    func yield(_ pcm: Data) {
        if case .dropped = continuation.yield(pcm) {
            let count = drops.withLock { $0 &+= 1; return $0 }
            // Log first and power-of-two drops without flooding the realtime callback.
            if count == 1 || count.nonzeroBitCount == 1 {
                Logger.audio.warning("Capture backlog dropped buffers: \(count)")
            }
        }
    }

    func finish() { continuation.finish() }
}

@Observable
final class AudioEngine: AudioEngineInterface {
    private(set) var isCapturing = false
    private(set) var isPlaying = false
    var onRuntimeEvent: ((AudioRuntimeEvent) -> Void)?

    /// Listener playback defaults to the receiver or connected headset so nearby
    /// speakers do not feed delayed tour audio back into the guide microphone.
    var listenerOutput: ListenerOutput = .privateAudio {
        didSet {
            guard isPlaying, oldValue != listenerOutput else { return }
            do {
                try playbackRuntime?.updateOutput(listenerOutput)
            } catch {
                failRuntime(.playback, error: error)
            }
        }
    }

    /// Noise gate threshold (RMS). Audio below this is suppressed.
    /// Suppresses low-level background noise. This is not echo cancellation.
    /// Range: 0.0 (disabled) to 1.0.
    /// Default is disabled to avoid dropping quiet speech during live chat.
    var noiseGateThreshold: Float = 0

    private var engine: AVAudioEngine?
    private var ownsCaptureAudioSession = false
    private var playbackRuntime: (any AudioPlaybackRuntimeInterface)?
    private let makePlaybackRuntime: () -> any AudioPlaybackRuntimeInterface
    private let notificationCenter: NotificationCenter
    private var activeRole: AudioRuntimeRole?
    private var interrupted = false
    private var acceptedPlaybackBuffer = false
    /// Bytes accepted by the renderer in this playback run, not acoustic output.
    private(set) var acceptedPlaybackByteCount: UInt64 = 0
    private var observerGeneration: UInt64 = 0
    private var hasCaptureTap = false
    private var captureStream: AudioCaptureStream?
    var droppedCaptureBufferCount: UInt64 { captureStream?.droppedBufferCount ?? 0 }
    private var routeChangeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// Input format the current converter was built for; a route change that alters it rebuilds the tap.
    private var captureInputFormat: AVAudioFormat?

    init(
        playbackRuntimeFactory: @escaping () -> any AudioPlaybackRuntimeInterface = { NativeAudioPlaybackRuntime() },
        notificationCenter: NotificationCenter = .default
    ) {
        makePlaybackRuntime = playbackRuntimeFactory
        self.notificationCenter = notificationCenter
    }

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
        stopPlayback()
        stopCapture()
#if targetEnvironment(simulator)
        Logger.audio.error("Microphone capture is unavailable in the iOS Simulator")
        throw AudioEngineError.captureUnavailable
#else
        try configureAudioSession(forCapture: true)
        ownsCaptureAudioSession = true
        logCurrentRoute("Capture")

        let engine = AVAudioEngine()
        self.engine = engine
        enableVoiceProcessingIfSupported(on: engine.inputNode)

        let captureStream = AudioCaptureStream()
        self.captureStream = captureStream

        do {
            try installCaptureTap(on: engine)
        } catch {
            cleanupCapturePipeline()
            throw error
        }

        do {
            try engine.start()
            isCapturing = true
            activeRole = .capture
            interrupted = false
            observeRouteChanges(for: .capture)
            onRuntimeEvent?(.started(.capture))
            Logger.audio.info("Capture engine started (noiseGate=\(self.noiseGateThreshold))")
        } catch {
            cleanupCapturePipeline()
            Logger.audio.error("Capture engine failed to start")
            throw AudioEngineError.captureStartFailed(error.localizedDescription)
        }

        return captureStream.stream
#endif
    }

    /// Builds the hardware-to-wire converter for the current input format and installs the tap.
    /// Called at capture start and again when a route or configuration change alters the input.
    private func installCaptureTap(on engine: AVAudioEngine) throws {
        guard let captureStream else { throw AudioEngineError.captureStartFailed("Capture stream is missing") }
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        Logger.audio.info("Hardware input: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Convert hardware format → wire format
        guard let converter = AVAudioConverter(from: hwFormat, to: Self.wireFormat) else {
            Logger.audio.error("Failed to create converter: \(hwFormat) → \(Self.wireFormat)")
            throw AudioEngineError.converterUnavailable
        }
        Logger.audio.info("Converter: \(hwFormat.sampleRate)Hz → \(Self.wireFormat.sampleRate)Hz")
        let converterRef = AudioConverterRef(converter: converter)
        let gateThreshold = noiseGateThreshold

        inputNode.installTap(
            onBus: 0,
            bufferSize: 345, // Requested ~7 ms at 48 kHz, but AVAudioEngine's input tap delivers ~100 ms buffers regardless (DSCN-5; LessonsLearned 58). The codec accumulator forms exact codec frames from whatever arrives.
            format: nil
        ) { @Sendable [converterRef, captureStream] buffer, _ in
            // Noise gate: compute RMS and drop quiet buffers (echo, background noise)
            if gateThreshold > 0, let rms = AudioEngine.rms(of: buffer), rms < gateThreshold {
                return // Below threshold — suppress
            }

            let outputBuffer = AudioEngine.convert(buffer, using: converterRef.converter)
            guard let finalBuffer = outputBuffer,
                  let data = AudioEngine.bufferToData(finalBuffer) else { return }
            captureStream.yield(data)
        }
        hasCaptureTap = true
        captureInputFormat = hwFormat
    }

    /// Route or configuration change while capturing (FND-13): tear down the tap built for the
    /// previous input format and rebuild it. An unrecoverable rebuild finishes the stream, which the
    /// product surfaces as "Microphone capture stopped" (DSCN-12).
    private func rebuildCapturePipeline() {
        guard let engine, isCapturing else { return }
        engine.stop()
        if hasCaptureTap {
            engine.inputNode.removeTap(onBus: 0)
            hasCaptureTap = false
        }
        do {
            try installCaptureTap(on: engine)
            try engine.start()
            Logger.audio.info("Capture pipeline rebuilt")
        } catch {
            Logger.audio.error("Capture pipeline rebuild failed (\(String(describing: type(of: error))))")
            failRuntime(.capture, error: error)
        }
    }

    /// Pure decision for the interruption observer: `.began` pauses, `.ended` with `.shouldResume`
    /// resumes, `.ended` without it stops, anything else is ignored.
    nonisolated static func interruptionAction(for userInfo: [AnyHashable: Any]?) -> CaptureInterruptionAction {
        guard let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return .ignore
        }
        switch type {
        case .began:
            return .pause
        case .ended:
            let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            return AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) ? .resume : .stop
        @unknown default:
            return .ignore
        }
    }

    /// Pure decision for the route-change observer: the converter is rebuilt when the input format
    /// it was built for differs from the current one, or when no converter exists.
    nonisolated static func needsConverterRebuild(current: AVAudioFormat, converterInput: AVAudioFormat?) -> Bool {
        guard let converterInput else { return true }
        return current.sampleRate != converterInput.sampleRate
            || current.channelCount != converterInput.channelCount
            || current.commonFormat != converterInput.commonFormat
    }

    func stopCapture() {
        guard isCapturing || engine != nil || ownsCaptureAudioSession else { return }
        cleanupCapturePipeline()
        Logger.audio.info("Capture stopped")
    }

    // MARK: - Playback

    func startPlayback() throws {
        stopCapture()
        stopPlayback()
        let runtime = makePlaybackRuntime()
        playbackRuntime = runtime
        do {
            try runtime.start(output: listenerOutput)
            isPlaying = true
            activeRole = .playback
            interrupted = false
            acceptedPlaybackBuffer = false
            acceptedPlaybackByteCount = 0
            observeRouteChanges(for: .playback)
            onRuntimeEvent?(.started(.playback))
            Logger.audio.info("Playback started (output=\(self.listenerOutput.rawValue))")
        } catch {
            // The runtime may have activated its session or attached nodes before failing.
            cleanupPlaybackPipeline()
            Logger.audio.error("Playback engine failed to start (\(String(describing: type(of: error))))")
            if let error = error as? AudioEngineError { throw error }
            throw AudioEngineError.playbackStartFailed(error.localizedDescription)
        }
    }

    func enqueuePlayback(_ data: Data) {
        guard isPlaying, let runtime = playbackRuntime, let buffer = Self.dataToBuffer(data) else {
            Logger.audio.debug("Dropped audio packet: \(data.count) bytes")
            return
        }
        guard runtime.enqueue(buffer) else {
            failRuntime(.playback, error: AudioEngineError.playbackStartFailed("The audio renderer stopped accepting buffers"))
            return
        }
        acceptedPlaybackByteCount += UInt64(data.count)
        if !acceptedPlaybackBuffer {
            acceptedPlaybackBuffer = true
            onRuntimeEvent?(.firstPlaybackBufferAccepted)
        }
    }

    func stopPlayback() {
        guard playbackRuntime != nil || activeRole == .playback else { return }
        cleanupPlaybackPipeline()
        Logger.audio.info("Playback stopped")
    }

    private func cleanupPlaybackPipeline() {
        removeObservers()
        playbackRuntime?.stop()
        playbackRuntime = nil
        isPlaying = false
        acceptedPlaybackBuffer = false
        interrupted = false
        activeRole = nil
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
        captureInputFormat = nil
        interrupted = false
        activeRole = nil
        removeObservers()
        captureStream?.finish()
        captureStream = nil
        if ownsCaptureAudioSession {
            ownsCaptureAudioSession = false
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Logger.audio.error("Capture session deactivation failed (\(String(describing: type(of: error))))")
            }
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

    private func observeRouteChanges(for role: AudioRuntimeRole) {
        removeObservers()
        let generation = observerGeneration
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            Task { @MainActor [weak self] in
                guard let self, self.observerGeneration == generation, self.activeRole == role else { return }
                self.handleRouteChange(reason)
            }
        }

        configChangeObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: role == .capture ? engine : playbackRuntime?.configurationChangeSource,
            queue: nil
        ) { [weak self] _ in
            // AVAudioEngine warns against releasing its engine synchronously inside this
            // notification. Hop off its callback queue, and reject events from replaced owners.
            Task { @MainActor [weak self] in
                guard let self, self.observerGeneration == generation, self.activeRole == role else { return }
                self.handleConfigurationChange()
            }
        }

        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let action = Self.interruptionAction(for: notification.userInfo)
            Task { @MainActor [weak self] in
                guard let self, self.observerGeneration == generation, self.activeRole == role else { return }
                self.handleInterruption(action)
            }
        }
    }

    /// Internal notification entry points also exercise the real lifecycle state machine with an
    /// injected hardware runtime. No notification-driven path may claim success on absent resources.
    func handleInterruption(_ action: CaptureInterruptionAction) {
        guard let role = activeRole else { return }
        switch action {
        case .pause:
            guard !interrupted else { return }
            interrupted = true
            if role == .capture {
                engine?.pause()
                isCapturing = false
            } else {
                playbackRuntime?.pause()
                isPlaying = false
                acceptedPlaybackBuffer = false
            }
            onRuntimeEvent?(.interrupted(role))
        case .resume:
            guard interrupted else { return }
            resumeRuntime(role)
        case .stop:
            guard interrupted else { return }
            failRuntime(role, error: AudioEngineError.audioRuntimeResumeFailed("The audio interruption ended without permission to resume"))
        case .ignore:
            break
        }
    }

    func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard let role = activeRole else { return }
        if role == .playback {
            // Respect headphone-disconnect privacy: never spill a previously private stream
            // onto a different output without an explicit retry by the guest.
            if reason == .oldDeviceUnavailable {
                failRuntime(.playback, error: AudioEngineError.audioRuntimeResumeFailed("The audio output disconnected. Retry Audio to use the current output"))
            } else if !interrupted, reason == .newDeviceAvailable || reason == .routeConfigurationChange {
                resumeRuntime(.playback)
            }
        } else if !interrupted, let engine,
                  Self.needsConverterRebuild(
                      current: engine.inputNode.outputFormat(forBus: 0),
                      converterInput: captureInputFormat
                  ) {
            rebuildCapturePipeline()
        }
    }

    func handleConfigurationChange() {
        guard let role = activeRole, !interrupted else { return }
        if role == .capture {
            rebuildCapturePipeline()
        } else {
            resumeRuntime(.playback)
        }
    }

    private func resumeRuntime(_ role: AudioRuntimeRole) {
        do {
            if role == .capture {
                guard let engine else {
                    throw AudioEngineError.audioRuntimeResumeFailed("Capture resources are unavailable")
                }
                try AVAudioSession.sharedInstance().setActive(true)
                engine.stop()
                if hasCaptureTap {
                    engine.inputNode.removeTap(onBus: 0)
                    hasCaptureTap = false
                }
                try installCaptureTap(on: engine)
                try engine.start()
                isCapturing = true
            } else {
                guard let playbackRuntime else {
                    throw AudioEngineError.audioRuntimeResumeFailed("Playback resources are unavailable")
                }
                try playbackRuntime.resume(output: listenerOutput)
                isPlaying = true
                acceptedPlaybackBuffer = false
            }
            interrupted = false
            onRuntimeEvent?(.resumed(role))
        } catch {
            failRuntime(role, error: error)
        }
    }

    private func failRuntime(_ role: AudioRuntimeRole, error: any Error) {
        Logger.audio.error("Audio runtime failed (role=\(String(describing: role)), error=\(String(describing: type(of: error))))")
        if role == .capture { cleanupCapturePipeline() } else { cleanupPlaybackPipeline() }
        onRuntimeEvent?(.failed(role, error.localizedDescription))
    }

    private func removeObservers() {
        observerGeneration &+= 1
        if let obs = routeChangeObserver {
            notificationCenter.removeObserver(obs)
            routeChangeObserver = nil
        }
        if let obs = configChangeObserver {
            notificationCenter.removeObserver(obs)
            configChangeObserver = nil
        }
        if let obs = interruptionObserver {
            notificationCenter.removeObserver(obs)
            interruptionObserver = nil
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
