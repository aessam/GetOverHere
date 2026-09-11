import AVFoundation
import Testing
@testable import GetOverHere

@Suite("Audio engine")
struct AudioEngineTests {
    @Test("Capture stream keeps only the newest pending buffer", arguments: [1, 2, 32])
    func captureStreamBoundsBacklog(bufferCount: Int) async {
        let capture = AudioCaptureStream()
        for index in 0..<bufferCount { capture.yield(Data([UInt8(index)])) }
        capture.finish()
        var iterator = capture.stream.makeAsyncIterator()
        #expect(await iterator.next() == Data([UInt8(bufferCount - 1)]))
        #expect(await iterator.next() == nil)
        #expect(capture.droppedBufferCount == UInt64(bufferCount - 1))
    }

    @Test("Finished capture cannot send late buffers into a replacement stream")
    func captureStreamReplacementIsIndependent() async {
        let old = AudioCaptureStream()
        old.finish()
        let replacement = AudioCaptureStream()
        old.yield(Data([1]))
        replacement.yield(Data([2]))
        old.finish()
        replacement.yield(Data([3]))
        replacement.finish()
        var oldIterator = old.stream.makeAsyncIterator()
        var replacementIterator = replacement.stream.makeAsyncIterator()
        #expect(await oldIterator.next() == nil)
        #expect(await replacementIterator.next() == Data([3]))
        #expect(await replacementIterator.next() == nil)
        #expect(old.droppedBufferCount == 0)
        #expect(replacement.droppedBufferCount == 1)
    }

    @Test("Simulator capture fails explicitly instead of publishing an empty stream")
    @MainActor
    func simulatorCaptureFailsExplicitly() {
#if targetEnvironment(simulator)
        let engine = AudioEngine()
        do {
            _ = try engine.startCapture()
            Issue.record("Simulator capture unexpectedly started")
        } catch let error as AudioEngineError {
            guard case .captureUnavailable = error else {
                Issue.record("Unexpected audio error: \(error)")
                return
            }
            #expect(!engine.isCapturing)
        } catch {
            Issue.record("Unexpected error type")
        }
#endif
    }

    @Test("Simulator playback fails explicitly and never reports a running renderer")
    @MainActor
    func simulatorPlaybackFailsExplicitly() {
#if targetEnvironment(simulator)
        let engine = AudioEngine()
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        do {
            try engine.startPlayback()
            Issue.record("Simulator playback unexpectedly started")
        } catch let error as AudioEngineError {
            guard case .playbackUnavailable = error else {
                Issue.record("Unexpected audio error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(!engine.isPlaying)
        #expect(events.isEmpty)
        engine.stopPlayback()
        engine.stopPlayback()
#endif
    }

    @Test("Partial playback startup failure cleans resources and permits retry")
    @MainActor
    func playbackStartupFailureCleansResources() throws {
        let runtime = StubAudioPlaybackRuntime()
        runtime.startError = AudioEngineError.audioSessionConfigurationFailed("injected failure")
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        #expect(throws: AudioEngineError.self) { try engine.startPlayback() }
        #expect(runtime.stopCalls == 1)
        #expect(!engine.isPlaying)
        #expect(events.isEmpty)
        engine.stopPlayback()
        #expect(runtime.stopCalls == 1)

        runtime.startError = nil
        try engine.startPlayback()
        #expect(engine.isPlaying)
        #expect(events == [.started(.playback)])
        engine.stopPlayback()
        engine.stopPlayback()
        #expect(runtime.stopCalls == 2)
    }

    @Test("Interrupted playback drops incoming PCM and rearms readiness after resume")
    @MainActor
    func playbackInterruptionDropsBuffersAndRearmsReadiness() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        try engine.startPlayback()
        engine.enqueuePlayback(Data([0, 1]))
        engine.enqueuePlayback(Data([2, 3]))
        #expect(runtime.enqueueCalls == 2)
        #expect(engine.acceptedPlaybackByteCount == 4)
        #expect(events == [.started(.playback), .firstPlaybackBufferAccepted])

        engine.handleInterruption(.pause)
        engine.handleInterruption(.pause)
        #expect(!engine.isPlaying)
        #expect(runtime.pauseCalls == 1)
        engine.enqueuePlayback(Data([4, 5]))
        #expect(runtime.enqueueCalls == 2)
        #expect(engine.acceptedPlaybackByteCount == 4)
        engine.handleConfigurationChange()
        #expect(runtime.resumeCalls == 0)

        engine.handleInterruption(.resume)
        #expect(engine.isPlaying)
        #expect(runtime.resumeCalls == 1)
        engine.enqueuePlayback(Data([6, 7]))
        #expect(runtime.enqueueCalls == 3)
        #expect(engine.acceptedPlaybackByteCount == 6)
        #expect(events == [.started(.playback), .firstPlaybackBufferAccepted, .interrupted(.playback), .resumed(.playback), .firstPlaybackBufferAccepted])
        engine.stopPlayback()
        try engine.startPlayback()
        #expect(engine.acceptedPlaybackByteCount == 0)
        engine.stopPlayback()
    }

    @Test("Resume failure stops playback, reports its role, and does not accept more PCM")
    @MainActor
    func playbackResumeFailureIsReported() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        try engine.startPlayback()
        runtime.resumeError = AudioEngineError.audioRuntimeResumeFailed("injected failure")
        engine.handleInterruption(.pause)
        engine.handleInterruption(.resume)
        #expect(!engine.isPlaying)
        #expect(runtime.stopCalls == 1)
        guard case let .failed(role, message) = events.last else {
            Issue.record("Missing playback failure event")
            return
        }
        #expect(role == .playback)
        #expect(message.contains("injected failure"))
        engine.enqueuePlayback(Data([0, 1]))
        #expect(runtime.enqueueCalls == 0)
        engine.handleInterruption(.resume)
        #expect(runtime.resumeCalls == 1)
    }

    @Test("Interruption without resume permission releases playback")
    @MainActor
    func interruptionWithoutResumePermissionStopsPlayback() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        try engine.startPlayback()
        engine.handleInterruption(.pause)
        engine.handleInterruption(.stop)
        #expect(!engine.isPlaying)
        #expect(runtime.stopCalls == 1)
        engine.handleConfigurationChange()
        #expect(runtime.resumeCalls == 0)
    }

    @Test("Playback configuration changes rebuild the runtime and rearm readiness")
    @MainActor
    func playbackConfigurationChangeRebuildsRuntime() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        try engine.startPlayback()
        engine.enqueuePlayback(Data([0, 1]))
        engine.handleConfigurationChange()
        engine.enqueuePlayback(Data([2, 3]))
        #expect(runtime.resumeCalls == 1)
        #expect(events == [.started(.playback), .firstPlaybackBufferAccepted, .resumed(.playback), .firstPlaybackBufferAccepted])
        engine.stopPlayback()
    }

    @Test("Headphone disconnection requires explicit retry and cannot be auto-resumed")
    @MainActor
    func headphoneDisconnectionStopsPlayback() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        try engine.startPlayback()
        engine.handleRouteChange(.oldDeviceUnavailable)
        #expect(!engine.isPlaying)
        #expect(runtime.stopCalls == 1)
        engine.handleRouteChange(.newDeviceAvailable)
        engine.handleConfigurationChange()
        #expect(runtime.resumeCalls == 0)
        guard case .failed(.playback, _) = events.last else {
            Issue.record("Headphone disconnect did not report playback failure")
            return
        }
    }

    @Test("Output selection failure reports failed playback instead of silent route fallback")
    @MainActor
    func outputSelectionFailureStopsPlayback() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        try engine.startPlayback()
        runtime.outputError = AudioEngineError.audioSessionConfigurationFailed("injected route failure")
        engine.listenerOutput = .speaker
        #expect(runtime.outputCalls == 1)
        #expect(!engine.isPlaying)
        #expect(runtime.stopCalls == 1)
    }

    @Test("Only renderer-accepted valid PCM reports playback readiness")
    @MainActor
    func playbackReadinessRequiresRendererAcceptance() throws {
        let runtime = StubAudioPlaybackRuntime()
        let engine = AudioEngine(playbackRuntimeFactory: { runtime })
        var events: [AudioRuntimeEvent] = []
        engine.onRuntimeEvent = { events.append($0) }
        try engine.startPlayback()
        engine.enqueuePlayback(Data())
        engine.enqueuePlayback(Data([0]))
        #expect(runtime.enqueueCalls == 0)
        #expect(events == [.started(.playback)])
        runtime.acceptsBuffers = false
        engine.enqueuePlayback(Data([0, 1]))
        #expect(runtime.enqueueCalls == 1)
        #expect(!engine.isPlaying)
        #expect(!events.contains(.firstPlaybackBufferAccepted))
        #expect(runtime.stopCalls == 1)
    }

    @Test("Playback installs interruption observers and ignores queued events from replaced owners", .timeLimit(.minutes(1)))
    @MainActor
    func playbackObserversRejectReplacedOwnerEvents() async throws {
        let first = StubAudioPlaybackRuntime()
        let second = StubAudioPlaybackRuntime()
        let center = NotificationCenter()
        var attempts = 0
        let engine = AudioEngine(playbackRuntimeFactory: {
            attempts += 1
            return attempts == 1 ? first : second
        }, notificationCenter: center)
        try engine.startPlayback()
        // Delivery hops onto MainActor, so teardown/replacement happens before the queued event.
        center.post(name: .AVAudioEngineConfigurationChange, object: first.configurationChangeSource)
        engine.stopPlayback()
        try engine.startPlayback()

        let (events, continuation) = AsyncStream.makeStream(of: AudioRuntimeEvent.self)
        engine.onRuntimeEvent = { continuation.yield($0) }
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .interrupted(.playback))
        #expect(first.stopCalls == 1)
        #expect(first.resumeCalls == 0)
        #expect(second.resumeCalls == 0)
        #expect(second.pauseCalls == 1)
        #expect(!engine.isPlaying)
        continuation.finish()
        engine.stopPlayback()
    }

    // FND-13: the observers themselves need audio hardware (simulator capture is unsupported by
    // design, CLAUDE.md), so the decisions they take are pure functions pinned here; headset
    // plug/unplug and an incoming call are P3 physical checklist items.

    @Test("Interruption notifications map to pause, resume, stop, or ignore")
    func interruptionActionMapping() {
        #expect(AudioEngine.interruptionAction(for: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ]) == .pause)
        #expect(AudioEngine.interruptionAction(for: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]) == .resume)
        #expect(AudioEngine.interruptionAction(for: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ]) == .stop)
        #expect(AudioEngine.interruptionAction(for: nil) == .ignore)
        #expect(AudioEngine.interruptionAction(for: [AVAudioSessionInterruptionTypeKey: "garbage"]) == .ignore)
        #expect(AudioEngine.interruptionAction(for: [AVAudioSessionInterruptionTypeKey: UInt(99)]) == .ignore)
    }

    @Test("Converter rebuild is required only when the input format changed")
    func converterRebuildDecision() throws {
        let mono48 = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let mono44 = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let stereo48 = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let int48 = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))

        #expect(!AudioEngine.needsConverterRebuild(current: mono48, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: mono44, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: stereo48, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: int48, converterInput: mono48))
        #expect(AudioEngine.needsConverterRebuild(current: mono48, converterInput: nil))
    }
}

/// Deliberate unit-test boundary: models native failure/cleanup, never installed in the app.
@MainActor
private final class StubAudioPlaybackRuntime: AudioPlaybackRuntimeInterface {
    let configurationChangeSource: AnyObject? = NSObject()
    var startError: (any Error)?
    var resumeError: (any Error)?
    var outputError: (any Error)?
    var acceptsBuffers = true
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var outputCalls = 0
    private(set) var enqueueCalls = 0
    private(set) var stopCalls = 0

    func start(output: ListenerOutput) throws {
        if let startError { throw startError }
    }

    func updateOutput(_ output: ListenerOutput) throws {
        outputCalls += 1
        if let outputError { throw outputError }
    }

    func pause() { pauseCalls += 1 }

    func resume(output: ListenerOutput) throws {
        resumeCalls += 1
        if let resumeError { throw resumeError }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        enqueueCalls += 1
        return acceptsBuffers
    }

    func stop() { stopCalls += 1 }
}
