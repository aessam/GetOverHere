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
import java.util.concurrent.RejectedExecutionException
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
    private data class SessionConfiguration(
        val sessionID: UUID,
        val participantID: UUID,
        val displayName: String,
        val platform: ParticipantPlatform,
        val credential: SessionCredential,
    )

    private data class ClientConnection(
        val socket: Socket,
        val writer: BoundedSocketFrameWriter,
        val connectionID: String,
        val participantID: UUID,
        val codec: SessionAudioCodec,
    )

    private class BroadcastCodecState(
        val encoder: RealtimeAudioEncoderInterface,
    ) {
        val accumulator = PCMFrameAccumulator(encoder.inputPCMByteCount)
        val streamID: UUID = UUID.randomUUID()
        var sequence: Long = 0
    }

    /**
     * Encode + seal + fan-out on one dedicated worker (FND-3, mirrors the iOS `audio.encode.seal`
     * queue of ADR-039). The capture flow is collected on the application's main dispatcher, so
     * running the codec there stalled the UI every 10 ms.
     */
    private class BroadcastProcessor(
        private val configured: SessionConfiguration,
        private val codecProvider: RealtimeAudioCodecProvider,
    ) {
        private val executor = Executors.newSingleThreadExecutor { body ->
            Thread(body, "audio-encode-seal").apply { isDaemon = true }
        }
        private val sealer = SessionFrameSealer(configured.credential)
        // Confined to the executor thread.
        private val codecStates = mutableMapOf<SessionAudioCodec, BroadcastCodecState>()
        private var sentPacketCount = 0
        @Volatile private var stopped = false

        fun submit(pcm: ByteArray, destinations: Map<SessionAudioCodec, List<BoundedSocketFrameWriter>>) {
            if (stopped) return
            try {
                executor.execute { process(pcm, destinations) }
            } catch (error: RejectedExecutionException) {
                Log.e(TAG, "TCP: encode worker rejected a frame after stop (${error.javaClass.simpleName})")
            }
        }

        fun stop() {
            stopped = true
            executor.execute {
                codecStates.values.forEach { it.encoder.close() }
                codecStates.clear()
            }
            executor.shutdown()
        }

        private fun process(pcm: ByteArray, destinations: Map<SessionAudioCodec, List<BoundedSocketFrameWriter>>) {
            if (stopped) return
            destinations.forEach { (codec, writers) ->
                if (writers.isEmpty()) return@forEach
                try {
                    val state = codecStates.getOrPut(codec) {
                        BroadcastCodecState(codecProvider.makeEncoder(codec))
                    }
                    state.accumulator.append(pcm).forEach { pcmFrame ->
                        val packet = state.encoder.encode(pcmFrame) ?: return@forEach
                        val capturedAt = wallClockNanoseconds()
                        val payload = EncodedAudioFramePayload(
                            packet.configuration,
                            capturedAt,
                            capturedAt + FRAME_LIFETIME_NANOSECONDS,
                            packet.bytes,
                        )
                        val logical = SessionEnvelope(
                            lane = SessionLane.REALTIME,
                            kind = SessionMessageKind.AUDIO_FRAME,
                            sequence = state.sequence++,
                            sessionId = configured.sessionID,
                            senderId = configured.participantID,
                            payload = payload.encode(),
                        )
                        val frame = sealer.seal(logical, state.streamID).encode()
                        sentPacketCount++
                        if (sentPacketCount == 1) {
                            Log.i(TAG, "TCP: sending first encrypted encoded audio frame")
                        }
                        writers.forEach { it.enqueue(frame) }
                    }
                } catch (error: Exception) {
                    Log.e(TAG, "TCP: encoded audio frame failed (${error.javaClass.simpleName})")
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
                        decoder.decode(decision.frame.payload.encodedBytes)?.let(onAudio)
                    is EncodedAudioPlayoutDecision.Conceal -> onAudio(silenceFrame)
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
            decoder.close()
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
    private val acceptExecutor = Executors.newSingleThreadExecutor()
    private val clientExecutor = Executors.newCachedThreadPool()
    /** Accepted-but-unauthenticated connections held at once (RSK-1, ADR-047). */
    private val handshakeSlots = Semaphore(MAXIMUM_PENDING_HANDSHAKES)
    private var receiveThread: Thread? = null
    @Volatile private var broadcastProcessor: BroadcastProcessor? = null
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
        configuration = SessionConfiguration(sessionID, participantID, displayName, platform, credential)
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
            broadcastProcessor = BroadcastProcessor(configured, codecProvider)

            acceptExecutor.execute {
                while (active.get()) {
                    val socket = try {
                        server.accept().apply { tcpNoDelay = true }
                    } catch (error: Exception) {
                        if (active.get()) Log.e(TAG, "TCP accept failed (${error.javaClass.simpleName})")
                        break
                    }
                    if (!handshakeSlots.tryAcquire()) {
                        Log.e(TAG, "TCP: pending handshake bound reached; closing connection")
                        closeSocket(socket)
                        continue
                    }
                    clientExecutor.execute {
                        authenticateAndMonitor(socket, configured, localCapabilities, epoch)
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
    ) {
        try {
            // The slot is held only while the handshake is pending: released exactly once on every
            // exit after the accept loop's tryAcquire, including a socket already closed here.
            val authenticated = try {
                socket.soTimeout = 5_000
                authenticateGuest(socket, configured, localCapabilities)
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
                connectionID = connectionID,
                participantID = envelope.senderId,
                codec = codec,
            )
            registerClient(client, hello.displayName, hello.platform)

            val unexpected = input.read()
            if (unexpected >= 0) Log.e(TAG, "TCP: guest sent unexpected post-hello data")
            removeClient(client)
        } catch (error: UnsupportedSessionVersionException) {
            if (active.get()) {
                sessionEventHandler?.invoke(
                    AudioSessionEvent.VersionMismatch(
                        error.receivedMajorVersion,
                        error.supportedMajorVersion,
                    ),
                )
            }
            closeSocket(socket)
        } catch (error: Exception) {
            if (active.get()) Log.e(TAG, "TCP: rejected or lost guest connection (${error.javaClass.simpleName})")
            closeSocket(socket)
        }
    }

    @Synchronized
    private fun registerClient(
        client: ClientConnection,
        displayName: String,
        platform: ParticipantPlatform,
    ) {
        if (!active.get() || client.writer.generation != runEpoch.get()) {
            client.writer.close()
            return
        }
        clients.firstOrNull { it.participantID == client.participantID }?.let(::removeClient)
        clients += client
        sessionEventHandler?.invoke(
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
        sessionEventHandler?.invoke(AudioSessionEvent.Disconnected(client.connectionID))
    }

    // MARK: - Guest

    override fun startListening(channelID: String, onAudio: (ByteArray) -> Unit) {
        val configured = configuration
        if (configured == null || !configured.sessionID.toString().equals(channelID, ignoreCase = true)) {
            Log.e(TAG, "TCP: missing or mismatched GOH2 session configuration")
            return
        }
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
        receivedPacketCount = 0
        receiveThread = Thread {
            var socket: Socket? = null
            var playout: PlayoutClock? = null
            var authenticated = false
            try {
                Log.i(TAG, "TCP: connecting to guide")
                val connected = guestSocketFactory.createSocket().apply {
                    tcpNoDelay = true
                    connect(InetSocketAddress(host, audioPort), 5_000)
                }
                socket = connected
                clientSocket = connected
                val output = connected.getOutputStream()
                connected.soTimeout = 5_000
                val guideID = authenticateGuide(connected, output, configured, localCapabilities)
                authenticated = true
                connected.soTimeout = 0
                Log.i(TAG, "TCP: authenticated GOH2 session joined")

                val input = connected.getInputStream()
                val opener = SessionFrameOpener(configured.credential)
                while (active.get()) {
                    val envelope = when (
                        val opened = opener.open(SealedSessionEnvelope.decode(readFrame(input, maximumFrameSize)))
                    ) {
                        is SessionFrameOpenResult.Opened -> opened.envelope
                        is SessionFrameOpenResult.Duplicate -> continue
                    }
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
                            onAudio = onAudio,
                            onDecodeFailure = {
                                emitFailedOnce(epoch, failureEmitted, "Native audio decode failed")
                                closeSocket(connected)
                            },
                        ).also { it.start() }
                    }
                    val clock = playout ?: continue
                    clock.offer(SequencedEncodedAudioFrame(envelope.sequence, encoded), wallClockNanoseconds())
                }
            } catch (error: UnsupportedSessionVersionException) {
                if (isRunActive(epoch)) {
                    sessionEventHandler?.invoke(
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

    /** Emits at most one [AudioSessionEvent.Failed] per guest run, and none for a superseded run. */
    private fun emitFailedOnce(epoch: Long, failureEmitted: AtomicBoolean, message: String) {
        if (isRunActive(epoch) && failureEmitted.compareAndSet(false, true)) {
            sessionEventHandler?.invoke(AudioSessionEvent.Failed(message))
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
        writeFrame(output, guideSealer.seal(challengeEnvelope, guideStreamID).encode())
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
        writeFrame(output, guideSealer.seal(welcome, guideStreamID).encode())
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

    private fun openFrame(frame: ByteArray, opener: SessionFrameOpener): SessionEnvelope? =
        when (val result = opener.open(SealedSessionEnvelope.decode(frame))) {
            is SessionFrameOpenResult.Opened -> result.envelope
            is SessionFrameOpenResult.Duplicate -> null
        }

    private fun closeSockets() {
        serverSocket?.let { server ->
            try {
                server.close()
            } catch (error: Exception) {
                Log.e(TAG, "TCP server close failed (${error.javaClass.simpleName})")
            }
        }
        clientSocket?.let(::closeSocket)
        clients.toList().forEach(::removeClient)
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
