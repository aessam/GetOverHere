package com.aessam.comeoverhere.service

import android.content.Context
import android.media.*
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.util.Log
import com.aessam.comeoverhere.core.ListenerOutput
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/**
 * Audio capture and playback engine matching the shared codec boundary:
 * 16 kHz mono signed PCM16 little-endian.
 *
 * Android AudioRecord supports 16kHz natively — no converter needed (unlike iOS).
 */
class AudioEngine(context: Context) {
    @Volatile var isCapturing = false; private set
    @Volatile var isPlaying = false; private set

    // Android microphone processing is device-dependent; a non-zero default gate
    // was suppressing speech on some devices when broadcasting to iOS.
    var noiseGateThreshold = 0f

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var emittedPacketCount = 0
    private val audioManager = context.applicationContext.getSystemService(AudioManager::class.java)
    private var listenerOutput = ListenerOutput.PRIVATE_AUDIO
    private var previousAudioMode: Int? = null

    companion object {
        private const val TAG = "AudioEngine"
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
     */
    fun startCapture(): Flow<ByteArray> = flow {
        enterCommunicationMode()
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, CAPTURE_ENCODING)
        val bufferSize = minBuffer * BUFFER_SIZE_FACTOR

        val record = AudioRecord.Builder()
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

        audioRecord = record

        // Enable echo cancellation and noise suppression
        val sessionId = record.audioSessionId
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(sessionId)?.also {
                it.enabled = true
                Log.i(TAG, "AEC enabled=${it.enabled}")
            }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(sessionId)?.also {
                it.enabled = true
                Log.i(TAG, "Noise suppressor enabled=${it.enabled}")
            }
        }

        record.startRecording()
        isCapturing = true
        emittedPacketCount = 0
        Log.i(TAG, "Capture started: ${SAMPLE_RATE}Hz mono PCM16")

        val pcmBuffer = ShortArray(160)
        try {
            while (isCapturing) {
                val read = withContext(Dispatchers.IO) {
                    record.read(pcmBuffer, 0, pcmBuffer.size, AudioRecord.READ_BLOCKING)
                }
                if (read > 0) {
                    val rms = computeRms(pcmBuffer, read)
                    if (rms < noiseGateThreshold) continue

                    val byteBuffer = ByteBuffer.allocate(read * Short.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
                    for (i in 0 until read) {
                        byteBuffer.putShort(pcmBuffer[i])
                    }
                    emittedPacketCount += 1
                    if (emittedPacketCount == 1) {
                        Log.i(TAG, "First capture packet emitted: ${byteBuffer.position()} bytes")
                    }
                    emit(byteBuffer.array())
                }
            }
        } finally {
            record.stop()
            record.release()
            aec?.release()
            ns?.release()
            audioRecord = null
            aec = null
            ns = null
            isCapturing = false
            leaveCommunicationMode()
            Log.i(TAG, "Capture stopped")
        }
    }.flowOn(Dispatchers.IO)

    fun stopCapture() {
        isCapturing = false
    }

    fun startPlayback() {
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

        track.play()
        audioTrack = track
        isPlaying = true
        applyListenerOutputRoute()
        Log.i(TAG, "Playback started: ${SAMPLE_RATE}Hz mono PCM16")
    }

    fun setListenerOutput(output: ListenerOutput) {
        listenerOutput = output
        if (isPlaying) applyListenerOutputRoute()
    }

    fun enqueuePlayback(data: ByteArray) {
        val track = audioTrack ?: return
        if (data.isEmpty() || data.size % Short.SIZE_BYTES != 0) {
            Log.e(TAG, "Rejected invalid PCM16 playback packet: ${data.size} bytes")
            return
        }
        track.write(data, 0, data.size, AudioTrack.WRITE_NON_BLOCKING)
    }

    fun stopPlayback() {
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
        isPlaying = false
        leaveCommunicationMode()
        Log.i(TAG, "Playback stopped")
    }

    private fun enterCommunicationMode() {
        if (previousAudioMode == null) previousAudioMode = audioManager.mode
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
    }

    private fun leaveCommunicationMode() {
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
