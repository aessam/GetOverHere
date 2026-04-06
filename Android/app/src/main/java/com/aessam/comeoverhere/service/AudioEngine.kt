package com.aessam.comeoverhere.service

import android.media.*
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/**
 * Audio capture and playback engine matching iOS wire format:
 * 16kHz mono float32 (~64 KB/s).
 *
 * Android AudioRecord supports 16kHz natively — no converter needed (unlike iOS).
 */
class AudioEngine {
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

    companion object {
        private const val TAG = "AudioEngine"
        const val SAMPLE_RATE = 16000
        const val CHANNEL_IN = AudioFormat.CHANNEL_IN_MONO
        const val CHANNEL_OUT = AudioFormat.CHANNEL_OUT_MONO
        const val CAPTURE_ENCODING = AudioFormat.ENCODING_PCM_16BIT
        const val PLAYBACK_ENCODING = AudioFormat.ENCODING_PCM_FLOAT
        const val BUFFER_SIZE_FACTOR = 2
    }

    /**
     * Start capturing audio. Returns a Flow of float32 byte arrays (wire format).
     */
    fun startCapture(): Flow<ByteArray> = flow {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, CAPTURE_ENCODING)
        val bufferSize = minBuffer * BUFFER_SIZE_FACTOR

        val record = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.MIC)
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
                Log.i(TAG, "AEC enabled")
            }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(sessionId)?.also {
                it.enabled = true
                Log.i(TAG, "Noise suppressor enabled")
            }
        }

        record.startRecording()
        isCapturing = true
        emittedPacketCount = 0
        Log.i(TAG, "Capture started: ${SAMPLE_RATE}Hz mono pcm16 -> float32 wire")

        // 115 samples × 4 bytes = 460 bytes audio. With 36 channelID + 2 headers = 498 bytes.
        // Fits in one BLE MTU (512). Critical for cross-platform audio.
        val pcmBuffer = ShortArray(160)
        try {
            while (isCapturing) {
                val read = withContext(Dispatchers.IO) {
                    record.read(pcmBuffer, 0, pcmBuffer.size, AudioRecord.READ_BLOCKING)
                }
                if (read > 0) {
                    val rms = computeRms(pcmBuffer, read)
                    if (rms < noiseGateThreshold) continue

                    // Convert PCM16 samples to float32 wire format expected by iOS.
                    val byteBuffer = ByteBuffer.allocate(read * 4).order(ByteOrder.LITTLE_ENDIAN)
                    for (i in 0 until read) {
                        byteBuffer.putFloat((pcmBuffer[i] / Short.MAX_VALUE.toFloat()).coerceIn(-1f, 1f))
                    }
                    emittedPacketCount += 1
                    if (emittedPacketCount == 1) {
                        Log.i(TAG, "First capture packet emitted: ${byteBuffer.position()} bytes, rms=$rms")
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
            Log.i(TAG, "Capture stopped")
        }
    }.flowOn(Dispatchers.IO)

    fun stopCapture() {
        isCapturing = false
    }

    fun startPlayback() {
        val minBuffer = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNEL_OUT, PLAYBACK_ENCODING)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
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
        Log.i(TAG, "Playback started: ${SAMPLE_RATE}Hz mono float32")
    }

    fun enqueuePlayback(data: ByteArray) {
        val track = audioTrack ?: return
        // Convert byte array back to float array
        val floatBuffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val floatArray = FloatArray(data.size / 4)
        for (i in floatArray.indices) {
            floatArray[i] = floatBuffer.getFloat()
        }
        track.write(floatArray, 0, floatArray.size, AudioTrack.WRITE_NON_BLOCKING)
    }

    fun stopPlayback() {
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
        isPlaying = false
        Log.i(TAG, "Playback stopped")
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
