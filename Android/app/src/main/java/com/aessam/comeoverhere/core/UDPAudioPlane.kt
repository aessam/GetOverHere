package com.aessam.comeoverhere.core

import android.os.SystemClock
import android.util.Log
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.EncodedAudioFramePayload
import com.aessam.toursession.EncodedAudioFrameOfferResult
import com.aessam.toursession.EncodedAudioJitterBuffer
import com.aessam.toursession.EncodedAudioPlayoutDecision
import com.aessam.toursession.PCMFrameAccumulator
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SequencedEncodedAudioFrame
import com.aessam.toursession.SessionAudioCodec
import com.aessam.toursession.SessionAudioCodecConfiguration
import com.aessam.toursession.SessionAudioCodecNegotiation
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionAuthenticator
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import com.aessam.toursession.SessionCapability
import com.aessam.toursession.UnsupportedSessionVersionException
import com.aessam.toursession.WelcomePayload
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.SocketFactory

/**
 * Local-LAN TCP transport with GOH2 session and realtime framing.
 *
 * The class name remains temporarily stable while callers migrate away from
 * the legacy transport naming.
 */
class UDPAudioPlane(
    private val codecProvider: RealtimeAudioCodecProvider = NativeRealtimeAudioCodecFactory,
    private val audioPort: Int = 50_000,
) : AudioPlane {
    internal data class SessionConfiguration(
        val sessionID: UUID,
        val participantID: UUID,
        val displayName: String,
        val platform: ParticipantPlatform,
        val credential: SessionCredential,
        val authentication: SessionGuideAuthentication,
    )

    private data class ClientConnection(
        val socket: Socket,
        val writer: BoundedSocketFrameWriter,
        val participantLease: ParticipantConnectionBudget.Lease,
        val connectionID: String,
        val participantID: UUID,
        val codec: SessionAudioCodec,
        val eventTarget: ((AudioSessionEvent) -> Unit)?,
    )

    private data class CaptureOrigin(val wall: Long, val monotonic: Long)

    private class BroadcastCodecState(var encoder: RealtimeAudioEncoderInterface, var discontinuity: Long) {
        var encoderClosed = false
        var accumulator = PCMFrameAccumulator(encoder.inputPCMByteCount)
        var partialOrigin: CaptureOrigin? = null
        val pendingInputs = java.util.ArrayDeque<CaptureOrigin>()
        val streamID: UUID = UUID.randomUUID()
        var waitingSince: Long? = null
    }

    /**
     * Encode + seal + fan-out on one dedicated worker (FND-3, mirrors the iOS `audio.encode.seal`
     * queue of ADR-039). The capture flow is collected on the application's main dispatcher, so
     * running the codec there stalled the UI every 10 ms.
     */
    internal class BroadcastProcessor(
        private val configured: SessionConfiguration,
        private val codecProvider: RealtimeAudioCodecProvider,
        private val wallClock: () -> Long = ::wallClockNanoseconds,
        private val monotonicClock: () -> Long = System::nanoTime,
        private val emitFrame: (ByteArray, List<BoundedSocketFrameWriter>) -> Unit = { frame, writers -> writers.forEach { it.enqueue(frame) } },
        private val onEncoderFailure: (String) -> Unit = {},
    ) {
        private companion object {
            const val MAXIMUM_PENDING_ENTRIES = 8
            const val MAXIMUM_BUFFERED_CODEC_INPUTS = 8
            const val MAXIMUM_SUBMISSION_BYTES = 32_000
            const val MAXIMUM_CAPTURE_AGE_NANOSECONDS = 150_000_000L
            const val MAXIMUM_CODEC_STALL_NANOSECONDS = 2_000_000_000L
            const val MAXIMUM_ENCODER_REPLACEMENTS = 3
        }
        private val executor = Executors.newSingleThreadExecutor { body ->
            Thread(body, "audio-encode-seal").apply { isDaemon = true }
        }
        private val sealer = SessionFrameSealer(configured.credential)
        // Confined to the executor thread.
        private val codecStates = mutableMapOf<SessionAudioCodec, BroadcastCodecState>()
        // The guest playout timeline outlives an encoder instance, even with a fresh crypto stream.
        private val nextSequences = mutableMapOf<SessionAudioCodec, Long>()
        private val replacementCounts = mutableMapOf<SessionAudioCodec, Int>()
        private val failedCodecs = mutableSetOf<SessionAudioCodec>()
        private data class Entry(val pcm: ByteArray, val destinations: Map<SessionAudioCodec, List<BoundedSocketFrameWriter>>, val origin: CaptureOrigin)
        private val lock = Any()
        private val pending = java.util.ArrayDeque<Entry>()
        private var draining = false
        private var discontinuity = 0L
        private var cleaned = false
        @Volatile private var sentPacketCount = 0
        @Volatile var submittedCaptureEntries = 0L; private set
        @Volatile private var stopped = false
        @Volatile var droppedCaptureEntries = 0L; private set
        @Volatile var rejectedCodecInputs = 0L; private set
        @Volatile var expiredCodecOutputs = 0L; private set
        @Volatile var encoderResetCount = 0L; private set
        @Volatile var lastEncoderResetReason: String? = null; private set
        val pendingCaptureEntries: Int get() = synchronized(lock) { pending.size }
        fun diagnostics(): Map<String, Any> = mapOf("submittedCaptureEntries" to submittedCaptureEntries,
            "pendingCaptureEntries" to pendingCaptureEntries, "droppedCaptureEntries" to droppedCaptureEntries,
            "rejectedCodecInputs" to rejectedCodecInputs, "expiredCodecOutputs" to expiredCodecOutputs,
            "encoderResetCount" to encoderResetCount, "lastEncoderResetReason" to (lastEncoderResetReason ?: "none"),
            "sentFrameCount" to sentPacketCount)

        fun submit(pcm: ByteArray, destinations: Map<SessionAudioCodec, List<BoundedSocketFrameWriter>>) {
            val origin = CaptureOrigin(wallClock(), monotonicClock())
            synchronized(lock) {
                if (stopped) return
                submittedCaptureEntries++
                // Bound retained bytes as well as entry count; production capture submits 320 B.
                if (pcm.isEmpty() || pcm.size > MAXIMUM_SUBMISSION_BYTES || pcm.size % 2 != 0) {
                    dropEntry(); return
                }
                if (pending.size == MAXIMUM_PENDING_ENTRIES) { pending.removeFirst(); dropEntry() }
                pending.addLast(Entry(pcm.copyOf(), destinations, origin))
                if (!draining) { draining = true; executor.execute(::drain) }
            }
        }

        fun stop() {
            synchronized(lock) {
                if (stopped) return
                stopped = true
                droppedCaptureEntries += pending.size
                pending.clear()
                discontinuity++
                if (!draining) { draining = true; executor.execute(::drain) }
                executor.shutdown()
            }
        }

        private fun dropEntry() {
            droppedCaptureEntries++
            discontinuity++
        }

        private fun expired(origin: CaptureOrigin): Boolean =
            monotonicClock() - origin.monotonic >= MAXIMUM_CAPTURE_AGE_NANOSECONDS

        private fun drain() {
            while (true) {
                val next = synchronized(lock) {
                    if (stopped) null else pending.pollFirst()?.let { it to discontinuity }
                }
                if (next != null) { process(next.first, next.second); continue }
                synchronized(lock) {
                    if (!stopped && pending.isNotEmpty()) return@synchronized
                    draining = false
                    if (stopped && !cleaned) {
                        cleaned = true
                        codecStates.values.forEach(::closeStateEncoder)
                        codecStates.clear()
                    }
                    return
                }
            }
        }

        private fun closeEncoder(encoder: RealtimeAudioEncoderInterface) {
            try { encoder.close() }
            catch (error: Exception) { Log.e(TAG, "TCP: encoder cleanup failed (${error.javaClass.simpleName})") }
        }

        private fun closeStateEncoder(state: BroadcastCodecState) {
            if (state.encoderClosed) return
            state.encoderClosed = true
            closeEncoder(state.encoder)
        }

        private fun retireEncoder(codec: SessionAudioCodec, reason: String) {
            codecStates.remove(codec)?.let(::closeStateEncoder)
            val replacements = replacementCounts[codec] ?: 0
            lastEncoderResetReason = reason
            if (replacements >= MAXIMUM_ENCODER_REPLACEMENTS) {
                if (failedCodecs.add(codec)) {
                    val message = "Audio encoder $codec failed after $replacements recovery attempts. Restart the tour audio."
                    Log.e(TAG, message)
                    onEncoderFailure(message)
                }
            } else {
                replacementCounts[codec] = replacements + 1
                encoderResetCount++
                Log.e(TAG, "TCP: replacing $codec encoder ($reason, attempt ${replacements + 1})")
            }
            // Replace the crypto stream, but retain the codec's guest playout sequence.
        }

        private fun process(entry: Entry, generation: Long) {
            if (stopped) return
            if (expired(entry.origin)) { synchronized(lock) { dropEntry() }; return }
            entry.destinations.forEach { (codec, writers) ->
                if (writers.isEmpty() || codec in failedCodecs) return@forEach
                try {
                    val state = codecStates.getOrPut(codec) {
                        BroadcastCodecState(codecProvider.makeEncoder(codec), generation)
                    }
                    if (state.discontinuity != generation || state.partialOrigin?.let(::expired) == true) {
                        // Capture gaps invalidate partial PCM, not a warmed-up native codec.
                        // Preserve stamps of accepted inputs until delayed output is drained.
                        state.accumulator = PCMFrameAccumulator(state.encoder.inputPCMByteCount)
                        state.partialOrigin = null
                        state.discontinuity = generation
                    }
                    val partial = state.partialOrigin
                    val frames = state.accumulator.append(entry.pcm)
                    state.partialOrigin = if (state.accumulator.bufferedByteCount == 0) null
                        else if (frames.isEmpty()) partial ?: entry.origin else entry.origin
                    for ((index, pcmFrame) in frames.withIndex()) {
                        if (stopped) return@forEach
                        val inputOrigin = if (index == 0) partial ?: entry.origin else entry.origin
                        if (expired(inputOrigin)) {
                            synchronized(lock) { dropEntry() }
                            continue
                        }
                        if (state.waitingSince == null) state.waitingSince = monotonicClock()
                        val result = if (state.pendingInputs.size == MAXIMUM_BUFFERED_CODEC_INPUTS) {
                            // Do not accept a ninth input, but let a cold codec finally drain.
                            // Resetting here repeats the same eight-input startup forever.
                            // This complete PCM frame was never submitted. Do not invalidate
                            // the earlier accepted frame being drained in the same iteration.
                            synchronized(lock) { droppedCaptureEntries++ }
                            RealtimeAudioEncodeResult(false, state.encoder.drainOutput())
                        } else state.encoder.offer(pcmFrame)
                        if (result.inputAccepted) state.pendingInputs.addLast(inputOrigin)
                        else rejectedCodecInputs++
                        // A warmed codec may release its startup backlog as a burst. Drain
                        // at most the retained eight inputs now; one output per later capture
                        // would preserve stale AAC-sized pipeline delay indefinitely.
                        for (drainIndex in 0 until MAXIMUM_BUFFERED_CODEC_INPUTS) {
                            val packet = (if (drainIndex == 0) result.packet else {
                                if (state.pendingInputs.isEmpty()) break
                                state.encoder.drainOutput()
                            }) ?: break
                            val outputOrigin = state.pendingInputs.pollFirst()
                                ?: error("Encoder produced output without an accepted input")
                            // Even expired output proves codec progress. Capture expiry alone is not a stall.
                            state.waitingSince = if (state.pendingInputs.isEmpty()) null else monotonicClock()
                            if (stopped) return@forEach
                            if (expired(outputOrigin)) {
                                expiredCodecOutputs++
                                continue
                            }
                            val payload = EncodedAudioFramePayload(
                                packet.configuration,
                                outputOrigin.wall,
                                outputOrigin.wall + FRAME_LIFETIME_NANOSECONDS,
                                packet.bytes,
                            )
                            val logical = SessionEnvelope(
                                lane = SessionLane.REALTIME,
                                kind = SessionMessageKind.AUDIO_FRAME,
                                sequence = nextSequences.getOrDefault(codec, 0L).also {
                                    check(it < Long.MAX_VALUE) { "Audio sequence exhausted" }
                                    nextSequences[codec] = it + 1
                                },
                                sessionId = configured.sessionID,
                                senderId = configured.participantID,
                                payload = payload.encode(),
                            )
                            val frame = configured.authentication.encodeGuide(sealer.seal(logical, state.streamID))
                            synchronized(lock) {
                                if (!stopped && generation == discontinuity && !expired(outputOrigin)) {
                                    sentPacketCount++
                                    if (sentPacketCount == 1) Log.i(TAG, "TCP: sending first encrypted encoded audio frame")
                                    emitFrame(frame, writers)
                                } else if (!stopped) dropEntry()
                            }
                        }
                        if (state.waitingSince?.let { monotonicClock() - it >= MAXIMUM_CODEC_STALL_NANOSECONDS } == true) {
                            retireEncoder(codec, "no output for 2 seconds")
                            return@forEach
                        }
                    }
                } catch (error: Exception) {
                    Log.e(TAG, "TCP: encoded audio frame failed (${error.javaClass.simpleName})")
                    synchronized(lock) { dropEntry() }
                    retireEncoder(codec, error.javaClass.simpleName)
                }
            }
        }
    }

    /**
     * Clock-driven realtime playout (ADR-045). A fixed-rate timer at the negotiated frame duration
     * drains the jitter buffer on its own thread, decodes there (the native decoder never runs on
     * the receive thread), and conceals a single lost frame with one silence frame so the timeline
     * is preserved. Production calls [start] right after construction; tests drive [tick] with an
     * injected clock.
     */
    internal class PlayoutClock(
        private val decoder: RealtimeAudioDecoderInterface,
        private val clock: () -> Long,
        private val onAudio: (ByteArray) -> Unit,
        private val onDecodeFailure: () -> Unit,
    ) : AutoCloseable {
        val configuration: SessionAudioCodecConfiguration get() = decoder.configuration

        /** Exactly one negotiated frame of PCM16 zeros: sampleRate * frameDuration / 1000 * channels * 2. */
        val silenceFrame: ByteArray

        private val lock = Any()
        private val jitter: EncodedAudioJitterBuffer
        private val executor = Executors.newSingleThreadScheduledExecutor { body ->
            Thread(body, "goh2-audio-playout").apply { isDaemon = true }
        }
        @Volatile private var stopped = false
        private val failureReported = AtomicBoolean(false)
        private val closed = AtomicBoolean(false)

        init {
            val duration = configuration.frameDurationMilliseconds
            val targetFrames = maxOf(1, (60 + duration - 1) / duration)
            val maximumFrames = maxOf(targetFrames, (250 + duration - 1) / duration)
            jitter = EncodedAudioJitterBuffer(targetFrames, maximumFrames)
            silenceFrame = ByteArray(
                (configuration.sampleRate * duration / 1_000 * configuration.channelCount * 2).toInt(),
            )
        }

        fun start() {
            val duration = configuration.frameDurationMilliseconds.toLong()
            executor.scheduleAtFixedRate(::tick, duration, duration, TimeUnit.MILLISECONDS)
        }

        fun offer(frame: SequencedEncodedAudioFrame, nowNanoseconds: Long): EncodedAudioFrameOfferResult =
            synchronized(lock) { jitter.offer(frame, nowNanoseconds) }

        /** One playout period. Runs on the playout thread in production; tests call it directly. */
        internal fun tick() {
            if (stopped) return
            val decision = synchronized(lock) { jitter.popForPlayout(clock()) }
            try {
                when (decision) {
                    is EncodedAudioPlayoutDecision.Frame ->
                        decoder.decode(decision.frame.payload.encodedBytes)?.let { if (!stopped) onAudio(it) }
                    is EncodedAudioPlayoutDecision.Conceal -> if (!stopped) onAudio(silenceFrame)
                    EncodedAudioPlayoutDecision.Wait -> Unit
                }
            } catch (error: Exception) {
                // Mandatory: an uncaught exception silently cancels scheduleAtFixedRate.
                Log.e(TAG, "TCP: native audio decode failed (${error.javaClass.simpleName})")
                stopped = true
                if (failureReported.compareAndSet(false, true)) onDecodeFailure()
            }
        }

        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            stopped = true
            executor.shutdownNow()
            // The receive thread is interrupted by stop(); clear the flag so the wait is real.
            val wasInterrupted = Thread.interrupted()
            try {
                if (!executor.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                    Log.e(TAG, "TCP: playout thread did not stop before decoder close")
                }
            } catch (error: InterruptedException) {
                Log.e(TAG, "TCP: interrupted while stopping the playout thread (${error.javaClass.simpleName})")
            } finally {
                if (wasInterrupted) Thread.currentThread().interrupt()
            }
            try {
                decoder.close()
            } catch (error: Exception) {
                Log.e(TAG, "TCP: decoder cleanup failed (${error.javaClass.simpleName})")
                if (failureReported.compareAndSet(false, true)) onDecodeFailure()
            }
        }
    }

    private val maximumFrameSize = 1_048_576
    private val active = AtomicBoolean(false)
    private val runEpoch = AtomicLong(0)
    override val isActive: Boolean get() = active.get()

    @Volatile private var configuration: SessionConfiguration? = null
    @Volatile private var sessionEventHandler: ((AudioSessionEvent) -> Unit)? = null
    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private val clients = CopyOnWriteArrayList<ClientConnection>()
    private val participantBudget = ParticipantConnectionBudget()
    private val acceptExecutor = Executors.newSingleThreadExecutor()
    private val clientExecutor = Executors.newCachedThreadPool()
    /** Accepted-but-unauthenticated connections held at once (RSK-1, ADR-047). */
    private val handshakeSlots = Semaphore(MAXIMUM_PENDING_HANDSHAKES)
    private var receiveThread: Thread? = null
    @Volatile private var broadcastProcessor: BroadcastProcessor? = null
    fun captureDiagnostics(): Map<String, Any> = broadcastProcessor?.diagnostics() ?: emptyMap()
    private var receivedPacketCount = 0

    var hostIP: String? = null
    @Volatile private var guestSocketFactory: SocketFactory = SocketFactory.getDefault()

    /** Test accessor for socket-option and admission assertions (FND-4). */
    internal fun acceptedClientSockets(): List<Socket> = clients.map { it.socket }

    companion object {
        private const val TAG = "UDPAudioPlane"
        private const val FRAME_LIFETIME_NANOSECONDS = 500_000_000L
        private const val MAXIMUM_PENDING_HANDSHAKES = 32

        private fun wallClockNanoseconds(): Long = SystemClock.elapsedRealtimeNanos()
    }

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {
        configuration = SessionConfiguration(sessionID, participantID, displayName, platform, credential, authentication)
    }

    private var authentication: SessionGuideAuthentication = SessionGuideAuthentication.Unconfigured
    override fun configureGuideAuthentication(authentication: SessionGuideAuthentication) {
        this.authentication = authentication
    }

    override fun setSessionEventHandler(handler: ((AudioSessionEvent) -> Unit)?) {
        sessionEventHandler = handler
    }

    override fun setGuestSocketFactory(factory: SocketFactory?) {
        guestSocketFactory = factory ?: SocketFactory.getDefault()
    }

    // MARK: - Guide

    /** Synchronous and throwing (FND-2): the guide commits state only after the lane is listening. */
    override fun startBroadcasting(channelID: String, quality: AudioQuality) {
        val configured = configuration
        if (configured == null || !configured.sessionID.toString().equals(channelID, ignoreCase = true)) {
            Log.e(TAG, "TCP: missing or mismatched GOH2 session configuration")
            throw IllegalStateException("TCP: missing or mismatched GOH2 session configuration")
        }
        configured.authentication.requireGuide()
        val localCapabilities = try {
            codecProvider.sessionCapabilities().also { capabilities ->
                if (
                    capabilities and SessionCapability.OPUS_ENCODER.bit == 0L &&
                    capabilities and SessionCapability.AAC_LC_ENCODER.bit == 0L
                ) {
                    throw IllegalStateException("no native realtime encoder is available")
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "TCP: native realtime encoder probe failed (${error.javaClass.simpleName})")
            throw IllegalStateException("TCP: no native realtime encoder is available", error)
        }

        closeSockets()
        active.set(true)
        val epoch = runEpoch.incrementAndGet()
        try {
            val ip = findLocalIPv4()
            if (hostIP == null) hostIP = ip
            Log.i(TAG, "TCP: local server address resolved")

            val server = ServerSocket()
            server.reuseAddress = true
            server.bind(InetSocketAddress(audioPort), 64)
            serverSocket = server
            Log.i(TAG, "TCP: GOH2 server listening on 0.0.0.0:$audioPort")
            // Constructed after the bind so a bind failure cannot leak the encode executor (DSCN-28).
            val runEventHandler = sessionEventHandler
            broadcastProcessor = BroadcastProcessor(configured, codecProvider, onEncoderFailure = { message ->
                if (isRunActive(epoch)) runEventHandler?.invoke(AudioSessionEvent.Failed(message))
            })
            acceptExecutor.execute {
                while (isRunActive(epoch)) {
                    val socket = try {
                        server.accept().apply { tcpNoDelay = true }
                    } catch (error: Exception) {
                        if (isRunActive(epoch)) Log.e(TAG, "TCP accept failed (${error.javaClass.simpleName})")
                        break
                    }
                    if (!handshakeSlots.tryAcquire()) {
                        Log.e(TAG, "TCP: pending handshake bound reached; closing connection")
                        closeSocket(socket)
                        continue
                    }
                    clientExecutor.execute {
                        authenticateAndMonitor(socket, configured, localCapabilities, epoch, runEventHandler)
                    }
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "TCP server failed to start (${error.javaClass.simpleName})")
            active.set(false)
            closeSockets()
            throw IllegalStateException("TCP: server failed to start: ${error.message}", error)
        }
    }

    override fun sendAudio(data: ByteArray) {
        val processor = broadcastProcessor ?: return
        if (!active.get() || clients.isEmpty()) return
        processor.submit(
            data,
            clients.groupBy(ClientConnection::codec).mapValues { (_, connections) -> connections.map { it.writer } },
        )
    }

    private fun authenticateAndMonitor(
        socket: Socket,
        configured: SessionConfiguration,
        localCapabilities: Long,
        epoch: Long,
        runEventHandler: ((AudioSessionEvent) -> Unit)?,
    ) {
        var participantLease: ParticipantConnectionBudget.Lease? = null
        var registeredClient: ClientConnection? = null
        try {
            // The slot is held only while the handshake is pending: released exactly once on every
            // exit after the accept loop's tryAcquire, including a socket already closed here.
            val authenticated = try {
                socket.soTimeout = 5_000
                authenticateGuest(socket, configured, localCapabilities) { participantID ->
                    participantLease = reserveParticipant(participantID, epoch)
                }
            } finally {
                handshakeSlots.release()
            }
            val envelope = authenticated.first
            val hello = authenticated.second.first
            val codec = authenticated.second.second
            socket.soTimeout = 0
            val input = socket.getInputStream()
            val connectionID = UUID.randomUUID().toString()
            val writer = BoundedSocketFrameWriter(
                socket = socket,
                generation = epoch,
                label = "audio-frame-writer-$connectionID",
                capacity = 4,
                overflowPolicy = SocketFrameOverflowPolicy.DROP_OLDEST,
                sendTimeoutMillis = 500,
            ) { failedSocket, failedEpoch ->
                clients.firstOrNull {
                    it.socket === failedSocket && it.writer.generation == failedEpoch
                }?.let(::removeClient)
            }
            val client = ClientConnection(
                socket = socket,
                writer = writer,
                participantLease = requireNotNull(participantLease),
                connectionID = connectionID,
                participantID = envelope.senderId,
                codec = codec,
                eventTarget = runEventHandler,
            )
            registeredClient = client
            registerClient(client, hello.displayName, hello.platform)

            val unexpected = input.read()
            if (unexpected >= 0) Log.e(TAG, "TCP: guest sent unexpected post-hello data")
            removeClient(client)
        } catch (error: UnsupportedSessionVersionException) {
            if (isRunActive(epoch)) {
                runEventHandler?.invoke(
                    AudioSessionEvent.VersionMismatch(
                        error.receivedMajorVersion,
                        error.supportedMajorVersion,
                    ),
                )
            }
            closeSocket(socket)
        } catch (error: Exception) {
            if (isRunActive(epoch)) Log.e(TAG, "TCP: rejected or lost guest connection (${error.javaClass.simpleName})")
            closeSocket(socket)
        } finally {
            registeredClient?.let(::removeClient)
            participantLease?.close()
        }
    }

    @Synchronized private fun reserveParticipant(participantID: UUID, epoch: Long): ParticipantConnectionBudget.Lease {
        check(active.get() && epoch == runEpoch.get()) { "Audio room ended" }
        return checkNotNull(participantBudget.reserve(participantID)) { "Audio participant capacity reached (30)" }
    }

    @Synchronized
    private fun registerClient(
        client: ClientConnection,
        displayName: String,
        platform: ParticipantPlatform,
    ) {
        if (!active.get() || client.writer.generation != runEpoch.get()) {
            client.writer.close()
            client.participantLease.close()
            return
        }
        clients.firstOrNull { it.participantID == client.participantID }?.let(::removeClient)
        clients += client
        client.eventTarget?.invoke(
            AudioSessionEvent.Joined(
                ParticipantSession(
                    participantId = client.participantID,
                    connectionId = client.connectionID,
                    displayName = displayName,
                    role = SessionRole.GUEST,
                    platform = platform,
                ),
            ),
        )
        Log.i(TAG, "TCP: validated guest session")
    }

    @Synchronized
    private fun removeClient(client: ClientConnection) {
        if (!clients.remove(client)) return
        client.writer.close()
        client.participantLease.close()
        if (isRunActive(client.writer.generation)) {
            client.eventTarget?.invoke(AudioSessionEvent.Disconnected(client.connectionID))
        }
    }

    // MARK: - Guest

    override fun startListening(channelID: String, onAudio: (ByteArray) -> Unit) {
        val configured = configuration
        if (configured == null || !configured.sessionID.toString().equals(channelID, ignoreCase = true)) {
            Log.e(TAG, "TCP: missing or mismatched GOH2 session configuration")
            return
        }
        configured.authentication.requireGuest()
        val host = hostIP
        if (host == null) {
            Log.e(TAG, "TCP: no host IP to connect to")
            return
        }
        val localCapabilities = try {
            codecProvider.sessionCapabilities().also { capabilities ->
                if (
                    capabilities and SessionCapability.OPUS_DECODER.bit == 0L &&
                    capabilities and SessionCapability.AAC_LC_DECODER.bit == 0L
                ) {
                    throw IllegalStateException("no native realtime decoder is available")
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "TCP: native realtime decoder probe failed (${error.javaClass.simpleName})")
            return
        }

        active.set(true)
        val epoch = runEpoch.incrementAndGet()
        val failureEmitted = AtomicBoolean(false)
        val runEventHandler = sessionEventHandler
        val runSocketFactory = guestSocketFactory
        receivedPacketCount = 0
        receiveThread = Thread {
            var socket: Socket? = null
            var playout: PlayoutClock? = null
            var authenticated = false
            try {
                Log.i(TAG, "TCP: connecting to guide")
                val connected = runSocketFactory.createSocket()
                socket = connected
                if (!installGuestSocket(connected, epoch)) return@Thread
                connected.tcpNoDelay = true
                connected.connect(InetSocketAddress(host, audioPort), 5_000)
                if (!isRunActive(epoch)) return@Thread
                val output = connected.getOutputStream()
                connected.soTimeout = 5_000
                val guideID = authenticateGuide(connected, output, configured, localCapabilities)
                if (!isRunActive(epoch)) return@Thread
                authenticated = true
                connected.soTimeout = 0
                Log.i(TAG, "TCP: authenticated GOH2 session joined")

                val input = connected.getInputStream()
                val opener = SessionFrameOpener(configured.credential)
                while (isRunActive(epoch)) {
                    val envelope = when (
                        val opened = opener.open(configured.authentication.decodeGuide(readFrame(input, maximumFrameSize)))
                    ) {
                        is SessionFrameOpenResult.Opened -> opened.envelope
                        is SessionFrameOpenResult.Duplicate -> continue
                    }
                    if (!isRunActive(epoch)) return@Thread
                    if (
                        envelope.sessionId != configured.sessionID ||
                        envelope.senderId != guideID ||
                        envelope.kind != SessionMessageKind.AUDIO_FRAME ||
                        envelope.lane != SessionLane.REALTIME
                    ) {
                        throw IllegalArgumentException("unexpected GOH2 frame")
                    }
                    receivedPacketCount++
                    if (receivedPacketCount == 1) Log.i(TAG, "TCP: received first GOH2 audio frame")
                    val encoded = EncodedAudioFramePayload.decode(envelope.payload)
                    if (playout?.configuration != encoded.configuration) {
                        // The receive thread only offers; the clock drains, decodes, and conceals (ADR-045).
                        playout?.close()
                        playout = PlayoutClock(
                            decoder = codecProvider.makeDecoder(encoded.configuration),
                            clock = ::wallClockNanoseconds,
                            onAudio = { pcm -> if (isRunActive(epoch)) onAudio(pcm) },
                            onDecodeFailure = {
                                emitFailedOnce(epoch, failureEmitted, "Native audio decode failed", runEventHandler)
                                closeSocket(connected)
                            },
                        ).also { it.start() }
                    }
                    val clock = playout ?: continue
                    val offered = clock.offer(SequencedEncodedAudioFrame(envelope.sequence, encoded), wallClockNanoseconds())
                    if (receivedPacketCount % 100 == 0) {
                        Log.d(TAG, "TCP: received $receivedPacketCount audio frames; latest jitter result $offered")
                    }
                }
            } catch (error: GuideAuthenticationException) {
                if (isRunActive(epoch) && failureEmitted.compareAndSet(false, true)) {
                    runEventHandler?.invoke(AudioSessionEvent.AuthenticationFailed(requireNotNull(error.message)))
                }
            } catch (error: UnsupportedSessionVersionException) {
                if (isRunActive(epoch)) {
                    runEventHandler?.invoke(
                        AudioSessionEvent.VersionMismatch(
                            error.receivedMajorVersion,
                            error.supportedMajorVersion,
                        ),
                    )
                    failureEmitted.set(true)
                }
            } catch (error: Exception) {
                if (isRunActive(epoch)) {
                    Log.e(TAG, "TCP receive failed (${error.javaClass.simpleName})")
                    // Pre-authentication IllegalArgumentException is a credential or protocol
                    // rejection (a wrong tour code fails to open the guide's sealed challenge as
                    // SessionFrameSecurityException): log only, the control lane reports admission.
                    // Everything else, and anything after authentication, is transport loss.
                    if (authenticated || error !is IllegalArgumentException) {
                        emitFailedOnce(
                            epoch,
                            failureEmitted,
                            "Guide audio connection lost (${error.javaClass.simpleName})",
                            runEventHandler,
                        )
                    }
                }
            } finally {
                playout?.close()
                socket?.let(::closeSocket)
            }
        }.also {
            it.name = "goh2-audio-receive"
            it.isDaemon = true
            it.start()
        }
    }

    private fun isRunActive(epoch: Long): Boolean = active.get() && runEpoch.get() == epoch

    @Synchronized private fun installGuestSocket(socket: Socket, epoch: Long): Boolean {
        if (!isRunActive(epoch)) { closeSocket(socket); return false }
        clientSocket = socket
        return true
    }

    /** Emits at most one [AudioSessionEvent.Failed] per guest run, and none for a superseded run. */
    private fun emitFailedOnce(epoch: Long, failureEmitted: AtomicBoolean, message: String, handler: ((AudioSessionEvent) -> Unit)?) {
        if (isRunActive(epoch) && failureEmitted.compareAndSet(false, true)) {
            handler?.invoke(AudioSessionEvent.Failed(message))
        }
    }

    override fun stop() {
        active.set(false)
        runEpoch.incrementAndGet()
        closeSockets()
        receiveThread?.interrupt()
        receiveThread = null
        Log.i(TAG, "TCP: stopped")
    }

    override fun clearSession() {
        stop()
        configuration = null
        authentication = SessionGuideAuthentication.Unconfigured
    }

    // MARK: - Framing

    private fun writeFrame(output: OutputStream, data: ByteArray) {
        require(data.size <= Int.MAX_VALUE)
        output.write(ByteBuffer.allocate(4).putInt(data.size).array())
        output.write(data)
        output.flush()
    }

    private fun readFrame(input: InputStream, maximumSize: Int): ByteArray {
        val header = readExact(input, 4)
        val size = ByteBuffer.wrap(header).int
        if (size <= 0 || size > maximumSize) {
            throw IllegalArgumentException("invalid frame size $size")
        }
        return readExact(input, size)
    }

    private fun readExact(input: InputStream, count: Int): ByteArray {
        val data = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(data, offset, count - offset)
            if (read < 0) throw IllegalStateException("stream ended")
            offset += read
        }
        return data
    }

    private fun authenticateGuest(
        socket: Socket,
        configured: SessionConfiguration,
        guideCapabilities: Long,
        reserveParticipant: (UUID) -> Unit,
    ): Pair<SessionEnvelope, Pair<HelloPayload, SessionAudioCodec>> {
        val output = socket.getOutputStream()
        val guideSealer = SessionFrameSealer(configured.credential)
        val guestOpener = SessionFrameOpener(configured.credential)
        val guideStreamID = UUID.randomUUID()
        val challengeNonce = SessionAuthenticator.randomNonce()
        val challenge = AuthChallengePayload(SessionLane.REALTIME, challengeNonce)
        val challengeEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.AUTH_CHALLENGE,
            sequence = 0,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = challenge.encode(),
        )
        writeFrame(output, configured.authentication.encodeGuide(guideSealer.seal(challengeEnvelope, guideStreamID)))
        val envelope = openFrame(
            readFrame(socket.getInputStream(), 65_536),
            guestOpener,
        ) ?: throw IllegalArgumentException("duplicate audio guest hello")
        val hello = HelloPayload.decode(envelope.payload)
        if (
            envelope.sessionId != configured.sessionID ||
            envelope.kind != SessionMessageKind.HELLO ||
            envelope.lane != SessionLane.CONTROL ||
            envelope.senderId == configured.participantID ||
            hello.role != SessionRole.GUEST ||
            hello.requestedLane != SessionLane.REALTIME
        ) {
            throw IllegalArgumentException("invalid audio guest hello")
        }
        val expectedProof = SessionAuthenticator.guestProof(
            configured.credential,
            configured.sessionID,
            configured.participantID,
            envelope.senderId,
            SessionLane.REALTIME,
            challengeNonce,
            hello.clientNonce,
            hello.role,
            hello.platform,
            hello.capabilities,
            hello.displayName,
        )
        if (!SessionAuthenticator.securelyMatches(expectedProof, hello.credentialProof)) {
            throw IllegalArgumentException("tour code proof was rejected")
        }
        val codec = SessionAudioCodecNegotiation.preferredCodec(
            guideCapabilities,
            hello.capabilities,
        )
        // The peer has proved membership; reserve capacity before reporting a successful welcome.
        reserveParticipant(envelope.senderId)
        val guideNonce = SessionAuthenticator.randomNonce()
        val guideProof = SessionAuthenticator.guideProof(
            configured.credential,
            configured.sessionID,
            configured.participantID,
            envelope.senderId,
            SessionLane.REALTIME,
            challengeNonce,
            hello.clientNonce,
            guideNonce,
        )
        val welcome = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.WELCOME,
            sequence = 1,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = WelcomePayload(SessionLane.REALTIME, guideNonce, guideProof).encode(),
        )
        writeFrame(output, configured.authentication.encodeGuide(guideSealer.seal(welcome, guideStreamID)))
        return envelope to (hello to codec)
    }

    private fun authenticateGuide(
        socket: Socket,
        output: OutputStream,
        configured: SessionConfiguration,
        guestCapabilities: Long,
    ): UUID {
        val guideOpener = SessionFrameOpener(configured.credential)
        val challengeEnvelope = openFrame(
            readFrame(socket.getInputStream(), 65_536),
            guideOpener,
            configured.authentication,
        ) ?: throw IllegalArgumentException("duplicate audio authentication challenge")
        if (
            challengeEnvelope.sessionId != configured.sessionID ||
            challengeEnvelope.kind != SessionMessageKind.AUTH_CHALLENGE ||
            challengeEnvelope.lane != SessionLane.CONTROL ||
            challengeEnvelope.senderId == configured.participantID
        ) {
            throw IllegalArgumentException("unexpected audio authentication challenge")
        }
        val challenge = AuthChallengePayload.decode(challengeEnvelope.payload)
        if (challenge.requestedLane != SessionLane.REALTIME) {
            throw IllegalArgumentException("audio challenge used the wrong lane")
        }
        val clientNonce = SessionAuthenticator.randomNonce()
        val proof = SessionAuthenticator.guestProof(
            configured.credential,
            configured.sessionID,
            challengeEnvelope.senderId,
            configured.participantID,
            SessionLane.REALTIME,
            challenge.challengeNonce,
            clientNonce,
            SessionRole.GUEST,
            configured.platform,
            guestCapabilities,
            configured.displayName,
        )
        val hello = HelloPayload(
            SessionRole.GUEST,
            configured.platform,
            guestCapabilities,
            configured.displayName,
            SessionLane.REALTIME,
            clientNonce,
            proof,
        )
        val helloEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.HELLO,
            sequence = 0,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = hello.encode(),
        )
        val guestSealer = SessionFrameSealer(configured.credential)
        writeFrame(output, guestSealer.seal(helloEnvelope, UUID.randomUUID()).encode())
        val welcomeEnvelope = openFrame(
            readFrame(socket.getInputStream(), 65_536),
            guideOpener,
            configured.authentication,
        ) ?: throw IllegalArgumentException("duplicate audio welcome")
        if (
            welcomeEnvelope.sessionId != configured.sessionID ||
            welcomeEnvelope.kind != SessionMessageKind.WELCOME ||
            welcomeEnvelope.lane != SessionLane.CONTROL ||
            welcomeEnvelope.senderId != challengeEnvelope.senderId
        ) {
            throw IllegalArgumentException("unexpected audio welcome")
        }
        val welcome = WelcomePayload.decode(welcomeEnvelope.payload)
        if (welcome.requestedLane != SessionLane.REALTIME) {
            throw IllegalArgumentException("audio welcome used the wrong lane")
        }
        val expectedProof = SessionAuthenticator.guideProof(
            configured.credential,
            configured.sessionID,
            challengeEnvelope.senderId,
            configured.participantID,
            SessionLane.REALTIME,
            challenge.challengeNonce,
            clientNonce,
            welcome.guideNonce,
        )
        if (!SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof)) {
            throw IllegalArgumentException("guide tour-code proof was rejected")
        }
        return challengeEnvelope.senderId
    }

    private fun openFrame(frame: ByteArray, opener: SessionFrameOpener, guide: SessionGuideAuthentication? = null): SessionEnvelope? =
        when (val result = opener.open(guide?.decodeGuide(frame) ?: SealedSessionEnvelope.decode(frame))) {
            is SessionFrameOpenResult.Opened -> result.envelope
            is SessionFrameOpenResult.Duplicate -> null
        }

    @Synchronized private fun closeSockets() {
        serverSocket?.let { server ->
            try {
                server.close()
            } catch (error: Exception) {
                Log.e(TAG, "TCP server close failed (${error.javaClass.simpleName})")
            }
        }
        clientSocket?.let(::closeSocket)
        clients.toList().forEach(::removeClient)
        participantBudget.clear()
        broadcastProcessor?.stop()
        broadcastProcessor = null
        serverSocket = null
        clientSocket = null
    }

    private fun closeSocket(socket: Socket) {
        try {
            socket.close()
        } catch (error: Exception) {
            Log.e(TAG, "TCP socket close failed (${error.javaClass.simpleName})")
        }
    }

    fun findHotspotIPPublic(): String? = findLocalIPv4()

    private fun findLocalIPv4(): String? {
        return try {
            val allInterfaces = java.net.NetworkInterface.getNetworkInterfaces()?.toList()
                ?.filter { it.isUp && !it.isLoopback }
                ?.flatMap { networkInterface ->
                    networkInterface.inetAddresses.toList().mapNotNull { address ->
                        if (address is java.net.Inet4Address) {
                            "${networkInterface.name}:${address.hostAddress}"
                        } else {
                            null
                        }
                    }
                } ?: emptyList()
            allInterfaces.firstOrNull {
                val name = it.substringBefore(":")
                name.startsWith("wlan") || name.startsWith("eth")
            }?.substringAfter(":") ?: allInterfaces.firstOrNull {
                val ip = it.substringAfter(":")
                ip.startsWith("192.168.") || ip.startsWith("10.") || ip.startsWith("172.")
            }?.substringAfter(":")
        } catch (error: Exception) {
            Log.e(TAG, "findLocalIPv4 failed (${error.javaClass.simpleName})")
            null
        }
    }
}
