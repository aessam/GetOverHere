package com.aessam.comeoverhere.core

import com.aessam.toursession.HelloPayload
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.SessionAuthenticator
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SessionFrameAuthenticationException
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.UnsupportedSessionVersionException
import com.aessam.toursession.WelcomePayload
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.SocketFactory

/**
 * The guide rejected the tour code: the sealed challenge or welcome failed AEAD authentication, or
 * the guide's proof mismatched. Never raised for an EOF or a malformed frame (DSCN-26).
 */
private class CredentialRejectedException(message: String) : IllegalArgumentException(message)

/** Reliable GOH2 control lane carried on a socket independent from live audio. */
private class LocalAuthenticatedSessionTransport(
    private val port: Int,
    private val applicationLane: SessionLane,
) {
    private data class Configuration(
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
        val participant: ParticipantSession,
        val participantLease: ParticipantConnectionBudget.Lease,
        val eventTarget: ((SessionControlEvent) -> Unit)?,
    )

    private val active = AtomicBoolean(false)
    private val sequence = AtomicLong(1)
    private val runEpoch = AtomicLong(0)
    private val clients = CopyOnWriteArrayList<ClientConnection>()
    private val participantBudget = ParticipantConnectionBudget()
    /** Accepted-but-unauthenticated connections held at once (RSK-1, ADR-047). */
    private val handshakeSlots = Semaphore(MAXIMUM_PENDING_HANDSHAKES)

    @Volatile private var configuration: Configuration? = null
    private var authentication: SessionGuideAuthentication = SessionGuideAuthentication.Unconfigured
    fun configureGuideAuthentication(value: SessionGuideAuthentication) { authentication = value }
    @Volatile private var eventHandler: ((SessionControlEvent) -> Unit)? = null
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var clientSocket: Socket? = null
    @Volatile private var guestWriter: BoundedSocketFrameWriter? = null
    @Volatile private var guestSocketFactory: SocketFactory = SocketFactory.getDefault()
    @Volatile private var outboundSealer: SessionFrameSealer? = null
    @Volatile private var outboundStreamID: UUID = UUID.randomUUID()

    val isActive: Boolean get() = active.get()
    @Volatile var hostIP: String? = null

    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {
        configuration = Configuration(sessionID, participantID, displayName, platform, credential, authentication)
    }

    fun setEventHandler(handler: ((SessionControlEvent) -> Unit)?) {
        eventHandler = handler
    }

    fun setGuestSocketFactory(factory: SocketFactory?) {
        guestSocketFactory = factory ?: SocketFactory.getDefault()
    }

    /** Synchronous and throwing (FND-2): the guide commits state only after every lane is listening. */
    fun startGuide() {
        val configured = configuration
            ?: throw IllegalStateException("Session: session is not configured")
        configured.authentication.requireGuide()

        active.set(false)
        closeSockets()
        val server = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(port), 64)
            }
        } catch (error: Exception) {
            throw IllegalStateException("Session: bind/listen failed: ${error.message}", error)
        }
        serverSocket = server
        sequence.set(1)
        outboundSealer = SessionFrameSealer(configured.credential)
        outboundStreamID = UUID.randomUUID()
        val inboundOpener = SessionFrameOpener(configured.credential)
        val epoch = runEpoch.incrementAndGet()
        active.set(true)
        val runEventHandler = eventHandler

        daemonThread("session-control-accept") {
            while (isRunActive(epoch)) {
                val socket = try {
                    server.accept().apply { tcpNoDelay = true }
                } catch (error: Exception) {
                    if (isRunActive(epoch)) {
                        runEventHandler?.invoke(SessionControlEvent.Failed("Session: accept failed: ${error.message}"))
                    }
                    break
                }
                if (!handshakeSlots.tryAcquire()) {
                    System.err.println("Session: pending handshake bound reached; closing connection")
                    socket.closeQuietly()
                    continue
                }
                daemonThread("session-control-guest") {
                    handleGuest(socket, configured, epoch, inboundOpener, runEventHandler)
                }
            }
        }
    }

    fun startGuest() {
        val configured = configuration
        if (configured == null) {
            emit(SessionControlEvent.Failed("Session: session is not configured"))
            return
        }
        configured.authentication.requireGuest()
        val host = hostIP
        if (host == null) {
            emit(SessionControlEvent.Failed("Session: guide host IP is missing"))
            return
        }

        active.set(false)
        closeSockets()
        sequence.set(1)
        outboundSealer = SessionFrameSealer(configured.credential)
        outboundStreamID = UUID.randomUUID()
        val inboundOpener = SessionFrameOpener(configured.credential)
        val epoch = runEpoch.incrementAndGet()
        active.set(true)
        val runEventHandler = eventHandler
        val runSocketFactory = guestSocketFactory
        fun emit(event: SessionControlEvent) { if (isRunActive(epoch)) runEventHandler?.invoke(event) }
        daemonThread("session-control-guide") {
            var openedSocket: Socket? = null
            var authenticated = false
            try {
                val socket = runSocketFactory.createSocket()
                openedSocket = socket
                if (!installGuestSocket(socket, epoch)) return@daemonThread
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(host, port), 5_000)
                if (!isRunActive(epoch)) return@daemonThread
                val output = socket.getOutputStream()

                socket.soTimeout = 5_000
                val guideID = authenticateGuide(socket, output, configured)
                socket.soTimeout = 0
                val writer = BoundedSocketFrameWriter(
                    socket = socket,
                    generation = epoch,
                    label = "session-data-guest-writer-$epoch",
                    capacity = if (applicationLane == SessionLane.CONTROL) 64 else 8,
                    overflowPolicy = SocketFrameOverflowPolicy.DISCONNECT,
                    sendTimeoutMillis = 2_000,
                ) { failedSocket, failedEpoch ->
                    if (isRunActive(failedEpoch) && clientSocket === failedSocket) {
                        clearClient(failedSocket)
                        emit(SessionControlEvent.Disconnected)
                    }
                }
                if (!installGuestWriter(socket, writer, epoch)) return@daemonThread
                authenticated = true
                emit(SessionControlEvent.Connected)

                val input = socket.getInputStream()
                while (isRunActive(epoch)) {
                    val envelope = openFrame(readFrame(input, MAXIMUM_FRAME_SIZE), inboundOpener, configured.authentication) ?: continue
                    if (
                        envelope.sessionId != configured.sessionID ||
                        envelope.senderId != guideID ||
                        envelope.lane != applicationLane ||
                        envelope.kind == SessionMessageKind.HELLO ||
                        envelope.kind == SessionMessageKind.AUTH_CHALLENGE ||
                        envelope.kind == SessionMessageKind.WELCOME
                    ) {
                        throw IllegalArgumentException("control envelope is not from the authenticated guide")
                    }
                    emit(SessionControlEvent.EnvelopeReceived(envelope))
                    if (envelope.kind == SessionMessageKind.LEAVE) break
                }
            } catch (error: UnsupportedSessionVersionException) {
                if (isRunActive(epoch)) {
                    emit(
                        SessionControlEvent.VersionMismatch(
                            error.receivedMajorVersion,
                            error.supportedMajorVersion,
                        ),
                    )
                }
            } catch (error: GuideAuthenticationException) {
                if (isRunActive(epoch)) emit(SessionControlEvent.AuthenticationFailed(requireNotNull(error.message)))
            } catch (error: CredentialRejectedException) {
                if (isRunActive(epoch)) {
                    emit(SessionControlEvent.CredentialRejected("Session: the tour code was rejected by the guide"))
                }
            } catch (error: Exception) {
                if (isRunActive(epoch)) {
                    emit(SessionControlEvent.Failed("Session: guide connection failed: ${error.message}"))
                }
            } finally {
                val wasActive = openedSocket != null && isRunActive(epoch) && clientSocket === openedSocket
                openedSocket?.let { socket -> clearClient(socket); socket.closeQuietly() }
                if (wasActive && authenticated) emit(SessionControlEvent.Disconnected)
            }
        }
    }

    /**
     * Synchronous send. A LEAVE blocks the caller for up to the 2 s delivery deadline and is reserved
     * for the process-termination path; product code ends a tour through [sendLeave].
     */
    fun send(kind: SessionMessageKind, payload: ByteArray, participantID: UUID?) {
        val (envelope, destinations) = sealedOutboundFrame(kind, payload, participantID) ?: return
        if (kind == SessionMessageKind.LEAVE) {
            val deliveries = destinations.mapNotNull { it.enqueue(envelope, trackDelivery = true) }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            if (deliveries.any { !it.await(deadline) }) {
                emit(SessionControlEvent.Failed("Session: terminal send did not complete before timeout"))
            }
        } else {
            destinations.forEach { it.enqueue(envelope) }
        }
    }

    /**
     * Enqueues one authenticated leave to every connected peer and suspends on `Dispatchers.IO`
     * until delivery or the 2 s deadline (FND-8): End Tour no longer blocks the main thread.
     */
    suspend fun sendLeave() {
        val (envelope, destinations) = sealedOutboundFrame(SessionMessageKind.LEAVE, byteArrayOf(), null) ?: return
        val deliveries = destinations.mapNotNull { it.enqueue(envelope, trackDelivery = true) }
        if (deliveries.isEmpty()) return
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        val timedOut = withContext(Dispatchers.IO) { deliveries.any { !it.await(deadline) } }
        if (timedOut) {
            emit(SessionControlEvent.Failed("Session: terminal send did not complete before timeout"))
        }
    }

    /** Seals one outbound frame and selects its writers; emits the failure and returns null otherwise. */
    private fun sealedOutboundFrame(
        kind: SessionMessageKind,
        payload: ByteArray,
        participantID: UUID?,
    ): Pair<ByteArray, List<BoundedSocketFrameWriter>>? {
        if (
            kind.requiredLane != applicationLane ||
            kind == SessionMessageKind.HELLO ||
            kind == SessionMessageKind.AUTH_CHALLENGE ||
            kind == SessionMessageKind.WELCOME
        ) {
            emit(SessionControlEvent.Failed("Session: ${kind.wireName} is not valid for the ${applicationLane.wireName} lane"))
            return null
        }
        val configured = configuration
        if (!active.get() || configured == null) {
            emit(SessionControlEvent.Failed("Session: transport is not active"))
            return null
        }
        val logicalEnvelope = SessionEnvelope(
            lane = applicationLane,
            kind = kind,
            sequence = sequence.getAndIncrement(),
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = payload,
        )
        val sealer = outboundSealer
        if (sealer == null) {
            emit(SessionControlEvent.Failed("Session: frame encryption is not configured"))
            return null
        }
        val envelope = try {
            val sealed = sealer.seal(logicalEnvelope, outboundStreamID)
            if (configured.authentication is SessionGuideAuthentication.Guest) sealed.encode()
            else configured.authentication.encodeGuide(sealed)
        } catch (error: Exception) {
            emit(SessionControlEvent.Failed("Session: envelope failed: ${error.message}"))
            return null
        }

        val guideDestinations = clients.filter {
            participantID == null || it.participant.participantId == participantID
        }.map(ClientConnection::writer)
        val guestDestination = if (participantID == null) guestWriter else null
        if (guideDestinations.isEmpty() && guestDestination == null) return null
        return envelope to (guideDestinations + listOfNotNull(guestDestination))
    }

    fun stop() {
        active.set(false)
        runEpoch.incrementAndGet()
        closeSockets()
    }

    fun clearSession() {
        stop()
        configuration = null
        authentication = SessionGuideAuthentication.Unconfigured
        outboundSealer = null
        outboundStreamID = UUID.randomUUID()
        sequence.set(1)
    }

    private fun handleGuest(
        socket: Socket,
        configured: Configuration,
        epoch: Long,
        inboundOpener: SessionFrameOpener,
        runEventHandler: ((SessionControlEvent) -> Unit)?,
    ) {
        fun emit(event: SessionControlEvent) { if (isRunActive(epoch)) runEventHandler?.invoke(event) }
        var client: ClientConnection? = null
        var participantLease: ParticipantConnectionBudget.Lease? = null
        try {
            // The slot is held only while the handshake is pending: released exactly once on every
            // exit after the accept loop's tryAcquire, including a socket already closed here.
            val authenticated = try {
                socket.soTimeout = 5_000
                authenticateGuest(socket, configured) { participantID ->
                    participantLease = reserveParticipant(participantID, epoch)
                }
            } finally {
                handshakeSlots.release()
            }
            val helloEnvelope = authenticated.first
            val hello = authenticated.second
            socket.soTimeout = 0

            val participant = ParticipantSession(
                participantId = helloEnvelope.senderId,
                connectionId = UUID.randomUUID().toString(),
                displayName = hello.displayName,
                role = SessionRole.GUEST,
                platform = hello.platform,
            )
            val writer = BoundedSocketFrameWriter(
                socket = socket,
                generation = epoch,
                label = "session-data-writer-${participant.connectionId}",
                capacity = if (applicationLane == SessionLane.CONTROL) 64 else 8,
                overflowPolicy = SocketFrameOverflowPolicy.DISCONNECT,
                sendTimeoutMillis = 2_000,
            ) { failedSocket, failedEpoch ->
                clients.firstOrNull {
                    it.socket === failedSocket && it.writer.generation == failedEpoch
                }?.let(::removeClient)
            }
            client = ClientConnection(socket, writer, participant, requireNotNull(participantLease), runEventHandler)
            registerClient(client, epoch)

            val input = socket.getInputStream()
            while (isRunActive(epoch)) {
                val envelope = openFrame(readFrame(input, MAXIMUM_FRAME_SIZE), inboundOpener) ?: continue
                if (!isRunActive(epoch)) return
                if (
                    envelope.sessionId != configured.sessionID ||
                    envelope.senderId != participant.participantId ||
                    envelope.lane != applicationLane ||
                    envelope.kind == SessionMessageKind.HELLO ||
                    envelope.kind == SessionMessageKind.AUTH_CHALLENGE ||
                    envelope.kind == SessionMessageKind.WELCOME
                ) {
                    throw IllegalArgumentException("control envelope is not from the authenticated guest")
                }
                emit(SessionControlEvent.EnvelopeReceived(envelope))
                if (envelope.kind == SessionMessageKind.LEAVE) break
            }
        } catch (error: UnsupportedSessionVersionException) {
            if (isRunActive(epoch)) {
                emit(
                    SessionControlEvent.VersionMismatch(
                        error.receivedMajorVersion,
                        error.supportedMajorVersion,
                    ),
                )
            }
        } catch (error: Exception) {
            if (isRunActive(epoch) && error !is EOFException) {
                emit(SessionControlEvent.Failed("Session: guest connection failed: ${error.message}"))
            }
        } finally {
            if (client != null) {
                removeClient(client)
            } else {
                socket.closeQuietly()
            }
            participantLease?.close()
        }
    }

    @Synchronized private fun reserveParticipant(participantID: UUID, epoch: Long): ParticipantConnectionBudget.Lease {
        check(isRunActive(epoch)) { "Session ended" }
        return checkNotNull(participantBudget.reserve(participantID)) { "Session participant capacity reached (30)" }
    }

    @Synchronized private fun registerClient(client: ClientConnection, epoch: Long) {
        if (!isRunActive(epoch)) {
            client.writer.close()
            client.participantLease.close()
            return
        }
        clients.firstOrNull { it.participant.participantId == client.participant.participantId }?.let(::removeClient)
        clients += client
        client.eventTarget?.invoke(SessionControlEvent.GuestJoined(client.participant))
    }

    @Synchronized private fun removeClient(client: ClientConnection) {
        if (!clients.remove(client)) return
        client.writer.close()
        client.participantLease.close()
        if (isRunActive(client.writer.generation)) {
            client.eventTarget?.invoke(SessionControlEvent.GuestDisconnected(client.participant.participantId))
        }
    }

    @Synchronized private fun installGuestSocket(socket: Socket, epoch: Long): Boolean {
        if (!isRunActive(epoch)) { socket.closeQuietly(); return false }
        clientSocket = socket
        return true
    }

    @Synchronized private fun installGuestWriter(socket: Socket, writer: BoundedSocketFrameWriter, epoch: Long): Boolean {
        if (!isRunActive(epoch) || clientSocket !== socket) { writer.close(); return false }
        guestWriter = writer
        return true
    }

    @Synchronized private fun clearClient(socket: Socket) {
        if (clientSocket === socket) {
            guestWriter?.close()
            guestWriter = null
            clientSocket = null
        }
    }

    @Synchronized private fun closeSockets() {
        serverSocket?.closeQuietly()
        serverSocket = null
        clientSocket?.closeQuietly()
        clientSocket = null
        guestWriter?.close()
        guestWriter = null
        clients.forEach { it.writer.close() }
        clients.clear()
        participantBudget.clear()
    }

    private fun emit(event: SessionControlEvent) {
        eventHandler?.invoke(event)
    }

    private fun isRunActive(epoch: Long): Boolean = active.get() && runEpoch.get() == epoch

    private fun authenticateGuest(
        socket: Socket,
        configured: Configuration,
        reserveParticipant: (UUID) -> Unit,
    ): Pair<SessionEnvelope, HelloPayload> {
        val output = socket.getOutputStream()
        val challengeNonce = SessionAuthenticator.randomNonce()
        val challenge = AuthChallengePayload(applicationLane, challengeNonce)
        val challengeEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.AUTH_CHALLENGE,
            sequence = 0,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = challenge.encode(),
        )
        val guideSealer = SessionFrameSealer(configured.credential)
        val guestOpener = SessionFrameOpener(configured.credential)
        val guideStreamID = UUID.randomUUID()
        writeFrame(output, configured.authentication.encodeGuide(guideSealer.seal(challengeEnvelope, guideStreamID)))
        val envelope = openFrame(
            readFrame(socket.getInputStream(), HELLO_MAXIMUM_SIZE),
            guestOpener,
        ) ?: throw IllegalArgumentException("duplicate guest hello")
        val hello = HelloPayload.decode(envelope.payload)
        if (
            envelope.sessionId != configured.sessionID ||
            envelope.kind != SessionMessageKind.HELLO ||
            envelope.lane != SessionLane.CONTROL ||
            envelope.senderId == configured.participantID ||
            hello.role != SessionRole.GUEST ||
            hello.requestedLane != applicationLane
        ) {
            throw IllegalArgumentException("invalid guest hello")
        }
        val expectedProof = SessionAuthenticator.guestProof(
            configured.credential,
            configured.sessionID,
            configured.participantID,
            envelope.senderId,
            applicationLane,
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
        reserveParticipant(envelope.senderId)
        val guideNonce = SessionAuthenticator.randomNonce()
        val guideProof = SessionAuthenticator.guideProof(
            configured.credential,
            configured.sessionID,
            configured.participantID,
            envelope.senderId,
            applicationLane,
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
            payload = WelcomePayload(applicationLane, guideNonce, guideProof).encode(),
        )
        writeFrame(output, configured.authentication.encodeGuide(guideSealer.seal(welcome, guideStreamID)))
        return envelope to hello
    }

    private fun authenticateGuide(
        socket: Socket,
        output: OutputStream,
        configured: Configuration,
    ): UUID {
        val guideOpener = SessionFrameOpener(configured.credential)
        // Only the AEAD failure is a credential rejection (DSCN-26); an EOF from readFrame stays a
        // transport failure and a malformed sealed frame stays a protocol failure.
        val challengeEnvelope = openHandshakeFrame(
            readFrame(socket.getInputStream(), MAXIMUM_FRAME_SIZE),
            guideOpener,
            configured.authentication,
        ) ?: throw IllegalArgumentException("duplicate authentication challenge")
        if (
            challengeEnvelope.sessionId != configured.sessionID ||
            challengeEnvelope.kind != SessionMessageKind.AUTH_CHALLENGE ||
            challengeEnvelope.lane != SessionLane.CONTROL ||
            challengeEnvelope.senderId == configured.participantID
        ) {
            throw IllegalArgumentException("unexpected authentication challenge")
        }
        val challenge = AuthChallengePayload.decode(challengeEnvelope.payload)
        if (challenge.requestedLane != applicationLane) {
            throw IllegalArgumentException("authentication challenge used the wrong lane")
        }
        val clientNonce = SessionAuthenticator.randomNonce()
        val proof = SessionAuthenticator.guestProof(
            configured.credential,
            configured.sessionID,
            challengeEnvelope.senderId,
            configured.participantID,
            applicationLane,
            challenge.challengeNonce,
            clientNonce,
            SessionRole.GUEST,
            configured.platform,
            0,
            configured.displayName,
        )
        val hello = HelloPayload(
            SessionRole.GUEST,
            configured.platform,
            0,
            configured.displayName,
            applicationLane,
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
        val welcomeEnvelope = openHandshakeFrame(
            readFrame(socket.getInputStream(), MAXIMUM_FRAME_SIZE),
            guideOpener,
            configured.authentication,
        ) ?: throw IllegalArgumentException("duplicate welcome envelope")
        if (
            welcomeEnvelope.sessionId != configured.sessionID ||
            welcomeEnvelope.kind != SessionMessageKind.WELCOME ||
            welcomeEnvelope.lane != SessionLane.CONTROL ||
            welcomeEnvelope.senderId != challengeEnvelope.senderId
        ) {
            throw IllegalArgumentException("unexpected welcome envelope")
        }
        val welcome = WelcomePayload.decode(welcomeEnvelope.payload)
        if (welcome.requestedLane != applicationLane) {
            throw IllegalArgumentException("welcome used the wrong lane")
        }
        val expectedProof = SessionAuthenticator.guideProof(
            configured.credential,
            configured.sessionID,
            challengeEnvelope.senderId,
            configured.participantID,
            applicationLane,
            challenge.challengeNonce,
            clientNonce,
            welcome.guideNonce,
        )
        if (!SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof)) {
            throw CredentialRejectedException("guide credential proof was rejected")
        }
        return challengeEnvelope.senderId
    }

    private fun openFrame(frame: ByteArray, opener: SessionFrameOpener, guide: SessionGuideAuthentication? = null): SessionEnvelope? =
        when (val result = opener.open(guide?.decodeGuide(frame) ?: SealedSessionEnvelope.decode(frame))) {
            is SessionFrameOpenResult.Opened -> result.envelope
            is SessionFrameOpenResult.Duplicate -> null
        }

    /** Guest-side handshake open: a wrong tour code fails the AEAD tag on the guide's sealed frame. */
    private fun openHandshakeFrame(frame: ByteArray, opener: SessionFrameOpener, guide: SessionGuideAuthentication): SessionEnvelope? =
        try {
            openFrame(frame, opener, guide)
        } catch (error: SessionFrameAuthenticationException) {
            throw CredentialRejectedException("tour code was rejected: ${error.message}")
        }

    private companion object {
        const val MAXIMUM_FRAME_SIZE = 1_048_576
        const val HELLO_MAXIMUM_SIZE = 65_536
        const val MAXIMUM_PENDING_HANDSHAKES = 32

        fun daemonThread(name: String, body: () -> Unit) {
            Thread(body, name).apply {
                isDaemon = true
                start()
            }
        }

        fun writeFrame(output: OutputStream, data: ByteArray) {
            require(data.size > 0)
            synchronized(output) {
                output.write(ByteBuffer.allocate(4).putInt(data.size).array())
                output.write(data)
                output.flush()
            }
        }

        fun readFrame(input: InputStream, maximumSize: Int): ByteArray {
            val length = ByteBuffer.wrap(readExact(input, 4)).int
            if (length <= 0 || length > maximumSize) {
                throw IllegalArgumentException("invalid frame length $length")
            }
            return readExact(input, length)
        }

        fun readExact(input: InputStream, count: Int): ByteArray {
            val bytes = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val received = input.read(bytes, offset, count - offset)
                if (received < 0) throw EOFException("socket closed")
                if (received == 0) continue
                offset += received
            }
            return bytes
        }

        fun AutoCloseable.closeQuietly() {
            try {
                close()
            } catch (error: Exception) {
                System.err.println("Session: socket close failed (${error.javaClass.simpleName})")
            }
        }
    }
}

class LocalSessionControlTransport(
    port: Int = 50_001,
) : SessionControlTransport {
    private val transport = LocalAuthenticatedSessionTransport(port, SessionLane.CONTROL)
    override fun configureGuideAuthentication(authentication: SessionGuideAuthentication) = transport.configureGuideAuthentication(authentication)

    override val isActive: Boolean get() = transport.isActive
    override var hostIP: String?
        get() = transport.hostIP
        set(value) {
            transport.hostIP = value
        }

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) = transport.configureSession(sessionID, participantID, displayName, platform, credential)

    override fun setEventHandler(handler: ((SessionControlEvent) -> Unit)?) =
        transport.setEventHandler(handler)

    override fun startGuide() = transport.startGuide()
    override fun startGuest() = transport.startGuest()
    override fun send(kind: SessionMessageKind, payload: ByteArray) =
        transport.send(kind, payload, null)
    override suspend fun sendLeave() = transport.sendLeave()
    override fun setGuestSocketFactory(factory: SocketFactory?) =
        transport.setGuestSocketFactory(factory)
    override fun stop() = transport.stop()
    override fun clearSession() = transport.clearSession()
}

class LocalSessionAssetTransport(
    port: Int = 50_002,
) : SessionAssetTransport {
    private val transport = LocalAuthenticatedSessionTransport(port, SessionLane.ASSET)
    override fun configureGuideAuthentication(authentication: SessionGuideAuthentication) = transport.configureGuideAuthentication(authentication)

    override val isActive: Boolean get() = transport.isActive
    override var hostIP: String?
        get() = transport.hostIP
        set(value) {
            transport.hostIP = value
        }

    override fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) = transport.configureSession(sessionID, participantID, displayName, platform, credential)

    override fun setEventHandler(handler: ((SessionAssetEvent) -> Unit)?) {
        transport.setEventHandler { event -> handler?.invoke(event.toAssetEvent()) }
    }

    override fun startGuide() = transport.startGuide()
    override fun startGuest() = transport.startGuest()
    override fun send(kind: SessionMessageKind, payload: ByteArray, participantID: UUID?) =
        transport.send(kind, payload, participantID)
    override fun setGuestSocketFactory(factory: SocketFactory?) =
        transport.setGuestSocketFactory(factory)
    override fun stop() = transport.stop()
    override fun clearSession() = transport.clearSession()
}

private fun SessionControlEvent.toAssetEvent(): SessionAssetEvent = when (this) {
    is SessionControlEvent.AuthenticationFailed -> SessionAssetEvent.AuthenticationFailed(message)
    SessionControlEvent.Connected -> SessionAssetEvent.Connected
    is SessionControlEvent.GuestJoined -> SessionAssetEvent.GuestJoined(participant)
    is SessionControlEvent.EnvelopeReceived -> SessionAssetEvent.EnvelopeReceived(envelope)
    is SessionControlEvent.GuestDisconnected -> SessionAssetEvent.GuestDisconnected(participantID)
    SessionControlEvent.Disconnected -> SessionAssetEvent.Disconnected
    is SessionControlEvent.VersionMismatch -> SessionAssetEvent.VersionMismatch(remoteMajor, localMajor)
    is SessionControlEvent.CredentialRejected -> SessionAssetEvent.CredentialRejected(message)
    is SessionControlEvent.Failed -> SessionAssetEvent.Failed(message)
}
