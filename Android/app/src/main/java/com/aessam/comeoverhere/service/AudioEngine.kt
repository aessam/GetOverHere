package com.aessam.comeoverhere.service

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.*
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.aessam.comeoverhere.core.ListenerOutput
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/** The `AudioTrack.write` seam: a JVM test cannot build an AudioTrack, so the loop is pure. */
internal fun interface PcmPlaybackSink {
    fun write(data: ByteArray, offset: Int, size: Int): Int
}

sealed interface PlaybackWriteOutcome {
    data object Written : PlaybackWriteOutcome
    /** The track buffer filled before the frame was consumed (timer-vs-DAC drift, FND-5). */
    data class Short(val written: Int, val expected: Int) : PlaybackWriteOutcome
    /** A negative `AudioTrack` error code such as `ERROR_DEAD_OBJECT`. */
    data class Failed(val code: Int) : PlaybackWriteOutcome
}

internal object PlaybackWriter {
    fun write(sink: PcmPlaybackSink, data: ByteArray): PlaybackWriteOutcome {
        var offset = 0
        while (offset < data.size) {
            val written = sink.write(data, offset, data.size - offset)
            if (written < 0) return PlaybackWriteOutcome.Failed(written)
            if (written == 0) return PlaybackWriteOutcome.Short(offset, data.size)
            offset += written
        }
        return PlaybackWriteOutcome.Written
    }
}

/** Native capture resources belong to one run, including when its Flow was never collected. */
internal class AudioCaptureRunOwner(private val lock: Any, private val onCurrentReleased: () -> Unit) {
    class Run internal constructor(internal val releaseResources: () -> Unit) {
        internal var released = false
    }
    private var current: Run? = null
    val isActive: Boolean get() = synchronized(lock) { current != null }
    fun start(releaseResources: () -> Unit): Run = synchronized(lock) {
        check(current == null) { "Previous microphone run must stop before replacement" }
        Run(releaseResources).also { current = it }
    }
    fun isCurrent(run: Run): Boolean = synchronized(lock) { current === run && !run.released }
    fun stop() = synchronized(lock) { current?.let(::release); Unit }
    fun release(run: Run) = synchronized(lock) {
        if (run.released) return@synchronized
        run.released = true
        val ownedCurrent = current === run
        if (ownedCurrent) current = null
        try { run.releaseResources() }
        finally { if (ownedCurrent) onCurrentReleased() }
    }
}

/** Explicitly fuses a newest-one handoff instead of flowOn's default buffered capture backlog. */
internal fun Flow<Pair<Long, ByteArray>>.newestCaptureBuffers(onDropped: (Long) -> Unit): Flow<ByteArray> =
    buffer(capacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST).let { latest ->
        flow {
            var previous = 0L
            latest.collect { (sequence, bytes) ->
                val dropped = sequence - previous - 1
                if (dropped > 0) onDropped(dropped)
                previous = sequence
                emit(bytes)
            }
        }
    }

/** Test seam (DSCN-23): the production engine needs a real AudioManager at construction. */
interface AudioEngineInterface {
    val isCapturing: Boolean
    val isPlaying: Boolean
    /** Invoked once per playback run with the first negative `AudioTrack.write` code. */
    var playbackFailureHandler: ((Int) -> Unit)?
    /** Once per renderer run, after decoded PCM bytes were accepted by AudioTrack. */
    var onPlaybackBufferAccepted: (() -> Unit)?
    /** Invoked after ACTION_AUDIO_BECOMING_NOISY forced the listener output back to private audio. */
    var onOutputForcedPrivate: (() -> Unit)?
    /** Invoked when another app takes audio focus permanently. */
    var onAudioFocusLost: (() -> Unit)?
    /** Throws synchronously when the microphone cannot start; the returned flow only reads. */
    fun startCapture(): Flow<ByteArray>
    fun stopCapture()
    fun startPlayback()
    fun enqueuePlayback(data: ByteArray)
    fun stopPlayback()
    fun setListenerOutput(output: ListenerOutput)
}

/**
 * Audio capture and playback engine matching the shared codec boundary:
 * 16 kHz mono signed PCM16 little-endian.
 *
 * Android AudioRecord supports 16kHz natively — no converter needed (unlike iOS).
 */
class AudioEngine(context: Context) : AudioEngineInterface {
    override val isCapturing: Boolean get() = captureRuns.isActive
    @Volatile override var isPlaying = false; private set

    /** Non-blocking writes that filled the track buffer; the drift signal P3 physical must record. */
    @Volatile var playbackShortWriteCount = 0; private set
    @Volatile var playbackWriteErrorCount = 0; private set
    @Volatile var captureDroppedBufferCount = 0L; private set
    override var playbackFailureHandler: ((Int) -> Unit)? = null
    override var onPlaybackBufferAccepted: (() -> Unit)? = null
    private var playbackBufferAccepted = false
    private var playbackFailureReported = false
    override var onOutputForcedPrivate: (() -> Unit)? = null
    override var onAudioFocusLost: (() -> Unit)? = null

    // Android microphone processing is device-dependent; a non-zero default gate
    // was suppressing speech on some devices when broadcasting to iOS.
    var noiseGateThreshold = 0f

    private var audioTrack: AudioTrack? = null
    private val captureRuns = AudioCaptureRunOwner(this) { if (!isPlaying) leaveCommunicationMode() }
    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(AudioManager::class.java)
    private var listenerOutput = DEFAULT_LISTENER_OUTPUT
    private var previousAudioMode: Int? = null
    private var focusRequest: AudioFocusRequest? = null
    private var noisyReceiverRegistered = false
    private val becomingNoisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) handleAudioBecomingNoisy()
        }
    }

    companion object {
        private const val TAG = "AudioEngine"
        /** Listener playback defaults to the receiver or connected headset (anti-feedback, ADR-034). */
        val DEFAULT_LISTENER_OUTPUT: ListenerOutput = ListenerOutput.PRIVATE_AUDIO
        const val SAMPLE_RATE = 16000
        const val CHANNEL_IN = AudioFormat.CHANNEL_IN_MONO
        const val CHANNEL_OUT = AudioFormat.CHANNEL_OUT_MONO
        const val CAPTURE_ENCODING = AudioFormat.ENCODING_PCM_16BIT
        const val PLAYBACK_ENCODING = AudioFormat.ENCODING_PCM_16BIT
        const val BUFFER_SIZE_FACTOR = 2
        private val PRIVATE_DEVICE_TYPES = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
        )
    }

    /**
     * Start capturing audio. Returns PCM16 little-endian byte arrays for the codec.
     *
     * The microphone preflight (permission, AudioRecord initialization, recording state) runs
     * synchronously and throws here (FND-2), so the guide's startup can roll back deterministically;
     * the returned flow only reads.
     */
    @Synchronized override fun startCapture(): Flow<ByteArray> {
        stopCapture()
        if (
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("Microphone permission is required to start capture")
        }
        enterCommunicationMode()
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, CAPTURE_ENCODING)
        val bufferSize = minBuffer * BUFFER_SIZE_FACTOR

        val record = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(CHANNEL_IN)
                        .setEncoding(CAPTURE_ENCODING)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .build()
        } catch (error: Exception) {
            leaveCommunicationMode()
            throw IllegalStateException("AudioRecord could not be created", error)
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            leaveCommunicationMode()
            throw IllegalStateException("AudioRecord failed to initialize")
        }

        var runAec: AcousticEchoCanceler? = null
        var runNoiseSuppressor: NoiseSuppressor? = null
        val run = captureRuns.start {
            val cleanups: List<() -> Unit> = listOf(
                { if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) record.stop() },
                { record.release() },
                { runAec?.release(); Unit },
                { runNoiseSuppressor?.release(); Unit },
            )
            cleanups.forEach { cleanup ->
                try { cleanup() }
                catch (error: Exception) { Log.e(TAG, "Capture resource cleanup failed (${error.javaClass.simpleName})") }
            }
        }
        try {
            val sessionId = record.audioSessionId
            if (AcousticEchoCanceler.isAvailable()) {
                runAec = AcousticEchoCanceler.create(sessionId)?.also {
                    it.enabled = true
                    Log.i(TAG, "AEC enabled=${it.enabled}")
                }
            }
            if (NoiseSuppressor.isAvailable()) {
                runNoiseSuppressor = NoiseSuppressor.create(sessionId)?.also {
                    it.enabled = true
                    Log.i(TAG, "Noise suppressor enabled=${it.enabled}")
                }
            }
            record.startRecording()
            check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "AudioRecord is not recording" }
        } catch (error: Exception) {
            captureRuns.release(run)
            throw IllegalStateException("AudioRecord failed to start recording", error)
        }
        Log.i(TAG, "Capture started: ${SAMPLE_RATE}Hz mono PCM16")
        captureDroppedBufferCount = 0

        return flow {
            val pcmBuffer = ShortArray(160)
            var emittedPacketCount = 0L
            try {
                while (captureRuns.isCurrent(run)) {
                    val read = withContext(Dispatchers.IO) {
                        record.read(pcmBuffer, 0, pcmBuffer.size, AudioRecord.READ_BLOCKING)
                    }
                    if (!captureRuns.isCurrent(run)) break
                    check(read >= 0) { "AudioRecord read failed ($read)" }
                    if (read > 0) {
                        val rms = computeRms(pcmBuffer, read)
                        if (rms < noiseGateThreshold) continue

                        val byteBuffer = ByteBuffer.allocate(read * Short.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
                        for (i in 0 until read) {
                            byteBuffer.putShort(pcmBuffer[i])
                        }
                        emittedPacketCount += 1
                        if (emittedPacketCount == 1L) {
                            Log.i(TAG, "First capture packet emitted: ${byteBuffer.position()} bytes")
                        }
                        emit(emittedPacketCount to byteBuffer.array())
                    }
                }
            } finally {
                captureRuns.release(run)
                Log.i(TAG, "Capture stopped")
            }
        }.flowOn(Dispatchers.IO).newestCaptureBuffers { dropped ->
            if (captureRuns.isCurrent(run)) captureDroppedBufferCount += dropped
        }
    }

    override fun stopCapture() = captureRuns.stop()

    @Synchronized override fun startPlayback() {
        stopCapture()
        stopPlayback()
        try {
            enterCommunicationMode()
        val minBuffer = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNEL_OUT, PLAYBACK_ENCODING)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(CHANNEL_OUT)
                    .setEncoding(PLAYBACK_ENCODING)
                    .build()
            )
            .setBufferSizeInBytes(minBuffer * BUFFER_SIZE_FACTOR)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        audioTrack = track
        check(track.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack failed to initialize" }
        track.play()
        check(track.playState == AudioTrack.PLAYSTATE_PLAYING) { "AudioTrack did not start playing" }
        isPlaying = true
        playbackFailureReported = false
        playbackBufferAccepted = false
        playbackShortWriteCount = 0
        playbackWriteErrorCount = 0
        applyListenerOutputRoute()
        if (!noisyReceiverRegistered) {
            ContextCompat.registerReceiver(
                appContext,
                becomingNoisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            noisyReceiverRegistered = true
        }
        Log.i(TAG, "Playback started: ${SAMPLE_RATE}Hz mono PCM16")
        } catch (error: Exception) {
            stopPlayback()
            throw error
        }
    }

    override fun setListenerOutput(output: ListenerOutput) {
        listenerOutput = output
        if (isPlaying) applyListenerOutputRoute()
    }

    /** Test accessor: the output the engine currently applies (FND-13). */
    internal val appliedListenerOutput: ListenerOutput get() = listenerOutput

    /**
     * A wired or Bluetooth output went away (FND-13): the system would otherwise fall back to the
     * loudspeaker, which feeds tour audio back into the guide's microphone. Force private output.
     */
    internal fun handleAudioBecomingNoisy() {
        if (!isPlaying) return
        Log.i(TAG, "Audio output became noisy; forcing private output")
        listenerOutput = ListenerOutput.PRIVATE_AUDIO
        applyListenerOutputRoute()
        onOutputForcedPrivate?.invoke()
    }

    internal fun handleAudioFocusChange(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                Log.e(TAG, "Audio focus lost")
                onAudioFocusLost?.invoke()
            }
            else -> Log.i(TAG, "Audio focus change $change ignored for voice communication")
        }
    }

    @Synchronized override fun enqueuePlayback(data: ByteArray) {
        if (!isPlaying) return
        val track = audioTrack ?: return
        if (data.isEmpty() || data.size % Short.SIZE_BYTES != 0) {
            Log.e(TAG, "Rejected invalid PCM16 playback packet: ${data.size} bytes")
            return
        }
        val outcome = PlaybackWriter.write(
            { buffer, offset, size -> track.write(buffer, offset, size, AudioTrack.WRITE_NON_BLOCKING) },
            data,
        )
        when (outcome) {
            PlaybackWriteOutcome.Written -> reportPlaybackAccepted()
            is PlaybackWriteOutcome.Short -> {
                if (outcome.written > 0) reportPlaybackAccepted()
                playbackShortWriteCount++
                if (playbackShortWriteCount == 1 || playbackShortWriteCount % 100 == 0) {
                    Log.e(
                        TAG,
                        "AudioTrack short write ${outcome.written}/${outcome.expected} bytes (count=$playbackShortWriteCount)",
                    )
                }
            }
            is PlaybackWriteOutcome.Failed -> {
                playbackWriteErrorCount++
                Log.e(TAG, "AudioTrack write failed: ${outcome.code} (count=$playbackWriteErrorCount)")
                if (!playbackFailureReported) {
                    playbackFailureReported = true
                    playbackFailureHandler?.invoke(outcome.code)
                }
            }
        }
    }

    private fun reportPlaybackAccepted() {
        if (playbackBufferAccepted) return
        playbackBufferAccepted = true
        onPlaybackBufferAccepted?.invoke()
    }

    @Synchronized override fun stopPlayback() {
        val track = audioTrack
        audioTrack = null
        isPlaying = false
        try {
            if (track?.state == AudioTrack.STATE_INITIALIZED) track.stop()
        } catch (error: IllegalStateException) {
            Log.e(TAG, "Could not stop AudioTrack; releasing failed renderer (${error.javaClass.simpleName})")
        } finally {
            track?.release()
        }
        if (noisyReceiverRegistered) {
            appContext.unregisterReceiver(becomingNoisyReceiver)
            noisyReceiverRegistered = false
        }
        leaveCommunicationMode()
        Log.i(TAG, "Playback stopped")
    }

    private fun enterCommunicationMode() {
        if (previousAudioMode == null) previousAudioMode = audioManager.mode
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (focusRequest == null) {
            // Voice communication holds focus for the whole tour (FND-13); a permanent loss is
            // surfaced to the product instead of leaving playback or capture silently ducked.
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setOnAudioFocusChangeListener(
                    AudioManager.OnAudioFocusChangeListener { change -> handleAudioFocusChange(change) },
                )
                .build()
            val result = audioManager.requestAudioFocus(request)
            if (result != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                Log.e(TAG, "Audio focus was not granted (result $result)")
                leaveCommunicationMode()
                throw IllegalStateException("Another app owns audio. Retry when it finishes.")
            }
            focusRequest = request
        }
    }

    private fun leaveCommunicationMode() {
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        focusRequest = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = false
        }
        previousAudioMode?.let { audioManager.mode = it }
        previousAudioMode = null
    }

    private fun applyListenerOutputRoute() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audioManager.availableCommunicationDevices
            val target = when (listenerOutput) {
                ListenerOutput.SPEAKER -> devices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                }
                ListenerOutput.PRIVATE_AUDIO -> devices.firstOrNull {
                    it.type in PRIVATE_DEVICE_TYPES
                } ?: devices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
            }
            if (target == null) {
                Log.e(TAG, "No communication device for ${listenerOutput.name}")
            } else {
                val applied = audioManager.setCommunicationDevice(target)
                Log.i(TAG, "Output route=${listenerOutput.name}, applied=$applied")
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = listenerOutput == ListenerOutput.SPEAKER
            Log.i(TAG, "Output route=${listenerOutput.name}, legacy=true")
        }
    }

    private fun computeRms(samples: ShortArray, count: Int): Float {
        var sum = 0f
        for (i in 0 until count) {
            val normalized = samples[i] / Short.MAX_VALUE.toFloat()
            sum += normalized * normalized
        }
        return sqrt(sum / count)
    }
}
