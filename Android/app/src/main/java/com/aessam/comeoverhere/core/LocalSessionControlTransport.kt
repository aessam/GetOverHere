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
import com.aessam.toursession.WelcomePayload
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.SocketFactory

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
    )

    private data class ClientConnection(
        val socket: Socket,
        val output: OutputStream,
        val participant: ParticipantSession,
    )

    private val active = AtomicBoolean(false)
    private val sequence = AtomicLong(1)
    private val runEpoch = AtomicLong(0)
    private val clients = CopyOnWriteArrayList<ClientConnection>()
    private val sendExecutor = Executors.newSingleThreadExecutor { body ->
        Thread(body, "session-data-send").apply { isDaemon = true }
    }

    @Volatile private var configuration: Configuration? = null
    @Volatile private var eventHandler: ((SessionControlEvent) -> Unit)? = null
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var clientSocket: Socket? = null
    @Volatile private var clientOutput: OutputStream? = null
    @Volatile private var guestSocketFactory: SocketFactory = SocketFactory.getDefault()

    val isActive: Boolean get() = active.get()
    @Volatile var hostIP: String? = null

    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {
        configuration = Configuration(sessionID, participantID, displayName, platform, credential)
    }

    fun setEventHandler(handler: ((SessionControlEvent) -> Unit)?) {
        eventHandler = handler
    }

    fun setGuestSocketFactory(factory: SocketFactory?) {
        guestSocketFactory = factory ?: SocketFactory.getDefault()
    }

    fun startGuide() {
        val configured = configuration
        if (configured == null) {
            emit(SessionControlEvent.Failed("Session: session is not configured"))
            return
        }

        active.set(false)
        closeSockets()
        val server = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(port), 64)
            }
        } catch (error: Exception) {
            emit(SessionControlEvent.Failed("Session: bind/listen failed: ${error.message}"))
            return
        }
        serverSocket = server
        sequence.set(1)
        val epoch = runEpoch.incrementAndGet()
        active.set(true)

        daemonThread("session-control-accept") {
            while (isRunActive(epoch)) {
                val socket = try {
                    server.accept().apply { tcpNoDelay = true }
                } catch (error: Exception) {
                    if (isRunActive(epoch)) {
                        emit(SessionControlEvent.Failed("Session: accept failed: ${error.message}"))
                    }
                    break
                }
                daemonThread("session-control-guest") {
                    handleGuest(socket, configured, epoch)
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
        val host = hostIP
        if (host == null) {
            emit(SessionControlEvent.Failed("Session: guide host IP is missing"))
            return
        }

        active.set(false)
        closeSockets()
        sequence.set(1)
        val epoch = runEpoch.incrementAndGet()
        active.set(true)
        daemonThread("session-control-guide") {
            val socket = guestSocketFactory.createSocket()
            var authenticated = false
            try {
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(host, port), 5_000)
                clientSocket = socket
                val output = socket.getOutputStream()
                clientOutput = output

                socket.soTimeout = 5_000
                val guideID = authenticateGuide(socket, output, configured)
                socket.soTimeout = 0
                authenticated = true
                emit(SessionControlEvent.Connected)

                val input = socket.getInputStream()
                while (isRunActive(epoch)) {
                    val envelope = SessionEnvelope.decode(readFrame(input, MAXIMUM_FRAME_SIZE))
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
                }
            } catch (error: Exception) {
                if (isRunActive(epoch)) {
                    emit(SessionControlEvent.Failed("Session: guide connection failed: ${error.message}"))
                }
            } finally {
                val wasActive = isRunActive(epoch) && clientSocket === socket
                clearClient(socket)
                socket.closeQuietly()
                if (wasActive && authenticated) emit(SessionControlEvent.Disconnected)
            }
        }
    }

    fun send(kind: SessionMessageKind, payload: ByteArray, participantID: UUID?) {
        if (
            kind.requiredLane != applicationLane ||
            kind == SessionMessageKind.HELLO ||
            kind == SessionMessageKind.AUTH_CHALLENGE ||
            kind == SessionMessageKind.WELCOME
        ) {
            emit(SessionControlEvent.Failed("Session: ${kind.wireName} is not valid for the ${applicationLane.wireName} lane"))
            return
        }
        val configured = configuration
        if (!active.get() || configured == null) {
            emit(SessionControlEvent.Failed("Session: transport is not active"))
            return
        }
        val envelope = SessionEnvelope(
            lane = applicationLane,
            kind = kind,
            sequence = sequence.getAndIncrement(),
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = payload,
        ).encode()

        val guideDestinations = clients.filter {
            participantID == null || it.participant.participantId == participantID
        }
        val guestDestination = if (participantID == null) clientOutput else null
        if (guideDestinations.isEmpty() && guestDestination == null) return

        sendExecutor.execute {
            guideDestinations.forEach { client ->
                try {
                    writeFrame(client.output, envelope)
                } catch (error: Exception) {
                    emit(SessionControlEvent.Failed("Session: guide send failed: ${error.message}"))
                    removeClient(client)
                }
            }
            if (guestDestination != null) {
                try {
                    writeFrame(guestDestination, envelope)
                } catch (error: Exception) {
                    emit(SessionControlEvent.Failed("Session: send failed: ${error.message}"))
                    val socket = clientSocket
                    if (socket != null) {
                        clearClient(socket)
                        socket.closeQuietly()
                    }
                }
            }
        }
    }

    fun stop() {
        active.set(false)
        runEpoch.incrementAndGet()
        closeSockets()
    }

    private fun handleGuest(socket: Socket, configured: Configuration, epoch: Long) {
        var client: ClientConnection? = null
        try {
            socket.soTimeout = 5_000
            val authenticated = authenticateGuest(socket, configured)
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
            val output = socket.getOutputStream()

            clients.firstOrNull { it.participant.participantId == participant.participantId }?.let {
                removeClient(it)
            }
            client = ClientConnection(socket, output, participant)
            clients += client
            emit(SessionControlEvent.GuestJoined(participant))

            val input = socket.getInputStream()
            while (isRunActive(epoch)) {
                val envelope = SessionEnvelope.decode(readFrame(input, MAXIMUM_FRAME_SIZE))
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
        }
    }

    private fun removeClient(client: ClientConnection) {
        if (!clients.remove(client)) return
        client.socket.closeQuietly()
        emit(SessionControlEvent.GuestDisconnected(client.participant.participantId))
    }

    private fun clearClient(socket: Socket) {
        if (clientSocket === socket) {
            clientSocket = null
            clientOutput = null
        }
    }

    private fun closeSockets() {
        serverSocket?.closeQuietly()
        serverSocket = null
        clientSocket?.closeQuietly()
        clientSocket = null
        clientOutput = null
        clients.forEach { it.socket.closeQuietly() }
        clients.clear()
    }

    private fun emit(event: SessionControlEvent) {
        eventHandler?.invoke(event)
    }

    private fun isRunActive(epoch: Long): Boolean = active.get() && runEpoch.get() == epoch

    private fun authenticateGuest(
        socket: Socket,
        configured: Configuration,
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
        writeFrame(output, challengeEnvelope.encode())
        val envelope = SessionEnvelope.decode(readFrame(socket.getInputStream(), HELLO_MAXIMUM_SIZE))
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
            sequence = 0,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = WelcomePayload(applicationLane, guideNonce, guideProof).encode(),
        )
        writeFrame(output, welcome.encode())
        return envelope to hello
    }

    private fun authenticateGuide(
        socket: Socket,
        output: OutputStream,
        configured: Configuration,
    ): UUID {
        val challengeEnvelope = SessionEnvelope.decode(readFrame(socket.getInputStream(), MAXIMUM_FRAME_SIZE))
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
        writeFrame(output, helloEnvelope.encode())
        val welcomeEnvelope = SessionEnvelope.decode(readFrame(socket.getInputStream(), MAXIMUM_FRAME_SIZE))
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
            throw IllegalArgumentException("guide credential proof was rejected")
        }
        return challengeEnvelope.senderId
    }

    private companion object {
        const val MAXIMUM_FRAME_SIZE = 1_048_576
        const val HELLO_MAXIMUM_SIZE = 65_536

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
    override fun setGuestSocketFactory(factory: SocketFactory?) =
        transport.setGuestSocketFactory(factory)
    override fun stop() = transport.stop()
}

class LocalSessionAssetTransport(
    port: Int = 50_002,
) : SessionAssetTransport {
    private val transport = LocalAuthenticatedSessionTransport(port, SessionLane.ASSET)

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
}

private fun SessionControlEvent.toAssetEvent(): SessionAssetEvent = when (this) {
    SessionControlEvent.Connected -> SessionAssetEvent.Connected
    is SessionControlEvent.GuestJoined -> SessionAssetEvent.GuestJoined(participant)
    is SessionControlEvent.EnvelopeReceived -> SessionAssetEvent.EnvelopeReceived(envelope)
    is SessionControlEvent.GuestDisconnected -> SessionAssetEvent.GuestDisconnected(participantID)
    SessionControlEvent.Disconnected -> SessionAssetEvent.Disconnected
    is SessionControlEvent.Failed -> SessionAssetEvent.Failed(message)
}
