package com.aessam.comeoverhere.core

import android.util.Log
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionAuthenticator
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
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
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.SocketFactory

/**
 * Local-LAN TCP transport with GOH2 session and realtime framing.
 *
 * The class name remains temporarily stable while callers migrate away from
 * the legacy transport naming.
 */
class UDPAudioPlane : AudioPlane {
    private data class SessionConfiguration(
        val sessionID: UUID,
        val participantID: UUID,
        val displayName: String,
        val platform: ParticipantPlatform,
        val credential: SessionCredential,
    )

    private data class ClientConnection(
        val socket: Socket,
        val output: OutputStream,
        val connectionID: String,
        val participantID: UUID,
    )

    private val audioPort = 50000
    private val maximumFrameSize = 1_048_576
    private val active = AtomicBoolean(false)
    override val isActive: Boolean get() = active.get()

    @Volatile private var configuration: SessionConfiguration? = null
    @Volatile private var sessionEventHandler: ((AudioSessionEvent) -> Unit)? = null
    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private val clients = CopyOnWriteArrayList<ClientConnection>()
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private val acceptExecutor = Executors.newSingleThreadExecutor()
    private val clientExecutor = Executors.newCachedThreadPool()
    private var receiveThread: Thread? = null
    private var sendSequence = 0L
    private var sentPacketCount = 0
    private var receivedPacketCount = 0

    var hostIP: String? = null
    @Volatile private var guestSocketFactory: SocketFactory = SocketFactory.getDefault()

    companion object {
        private const val TAG = "UDPAudioPlane"
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

    override fun startBroadcasting(channelID: String, quality: AudioQuality) {
        val configured = configuration
        if (configured == null || !configured.sessionID.toString().equals(channelID, ignoreCase = true)) {
            Log.e(TAG, "TCP: missing or mismatched GOH2 session configuration")
            return
        }

        closeSockets()
        active.set(true)
        sendSequence = 0
        sentPacketCount = 0
        try {
            val ip = findLocalIPv4()
            if (hostIP == null) hostIP = ip
            Log.i(TAG, "TCP: local server address resolved")

            val server = ServerSocket()
            server.reuseAddress = true
            server.bind(InetSocketAddress(audioPort), 64)
            serverSocket = server
            Log.i(TAG, "TCP: GOH2 server listening on 0.0.0.0:$audioPort")

            acceptExecutor.execute {
                while (active.get()) {
                    val socket = try {
                        server.accept()
                    } catch (error: Exception) {
                        if (active.get()) Log.e(TAG, "TCP accept failed (${error.javaClass.simpleName})")
                        break
                    }
                    clientExecutor.execute { authenticateAndMonitor(socket, configured) }
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "TCP server failed to start (${error.javaClass.simpleName})")
            active.set(false)
        }
    }

    override fun sendAudio(data: ByteArray) {
        val configured = configuration ?: return
        if (!active.get() || clients.isEmpty()) return

        val envelope = SessionEnvelope(
            lane = SessionLane.REALTIME,
            kind = SessionMessageKind.AUDIO_FRAME,
            sequence = sendSequence++,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = data,
        ).encode()

        sendExecutor.execute {
            sentPacketCount++
            if (sentPacketCount == 1) {
                Log.i(TAG, "TCP: sending first GOH2 audio frame to ${clients.size} client(s)")
            }
            clients.forEach { client ->
                try {
                    writeFrame(client.output, envelope)
                } catch (error: Exception) {
                    Log.e(TAG, "TCP send failed (${error.javaClass.simpleName})")
                    removeClient(client)
                }
            }
        }
    }

    private fun authenticateAndMonitor(socket: Socket, configured: SessionConfiguration) {
        try {
            socket.soTimeout = 5_000
            val input = socket.getInputStream()
            val authenticated = authenticateGuest(socket, configured)
            val envelope = authenticated.first
            val hello = authenticated.second
            socket.soTimeout = 0
            val client = ClientConnection(
                socket = socket,
                output = socket.getOutputStream(),
                connectionID = UUID.randomUUID().toString(),
                participantID = envelope.senderId,
            )
            registerClient(client, hello.displayName, hello.platform)

            val unexpected = input.read()
            if (unexpected >= 0) Log.e(TAG, "TCP: guest sent unexpected post-hello data")
            removeClient(client)
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
        closeSocket(client.socket)
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

        active.set(true)
        receivedPacketCount = 0
        receiveThread = Thread {
            var socket: Socket? = null
            try {
                Log.i(TAG, "TCP: connecting to guide")
                socket = guestSocketFactory.createSocket().apply {
                    connect(InetSocketAddress(host, audioPort), 5_000)
                }
                clientSocket = socket
                val output = socket.getOutputStream()
                socket.soTimeout = 5_000
                val guideID = authenticateGuide(socket, output, configured)
                socket.soTimeout = 0
                Log.i(TAG, "TCP: authenticated GOH2 session joined")

                val input = socket.getInputStream()
                while (active.get()) {
                    val envelope = SessionEnvelope.decode(readFrame(input, maximumFrameSize))
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
                    onAudio(envelope.payload)
                }
            } catch (error: Exception) {
                if (active.get()) Log.e(TAG, "TCP receive failed (${error.javaClass.simpleName})")
            } finally {
                socket?.let(::closeSocket)
            }
        }.also {
            it.name = "goh2-audio-receive"
            it.isDaemon = true
            it.start()
        }
    }

    override fun stop() {
        active.set(false)
        closeSockets()
        receiveThread?.interrupt()
        receiveThread = null
        Log.i(TAG, "TCP: stopped")
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
    ): Pair<SessionEnvelope, HelloPayload> {
        val output = socket.getOutputStream()
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
        writeFrame(output, challengeEnvelope.encode())
        val envelope = SessionEnvelope.decode(readFrame(socket.getInputStream(), 65_536))
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
            sequence = 0,
            sessionId = configured.sessionID,
            senderId = configured.participantID,
            payload = WelcomePayload(SessionLane.REALTIME, guideNonce, guideProof).encode(),
        )
        writeFrame(output, welcome.encode())
        return envelope to hello
    }

    private fun authenticateGuide(
        socket: Socket,
        output: OutputStream,
        configured: SessionConfiguration,
    ): UUID {
        val challengeEnvelope = SessionEnvelope.decode(readFrame(socket.getInputStream(), 65_536))
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
            0,
            configured.displayName,
        )
        val hello = HelloPayload(
            SessionRole.GUEST,
            configured.platform,
            0,
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
        writeFrame(output, helloEnvelope.encode())
        val welcomeEnvelope = SessionEnvelope.decode(readFrame(socket.getInputStream(), 65_536))
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
