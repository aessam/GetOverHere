package com.aessam.comeoverhere.core

import android.util.Log
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.AssetRequestPayload
import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.RelayHostAdvert
import com.aessam.toursession.RelayLaneAuthenticator
import com.aessam.toursession.RelayLaneContext
import com.aessam.toursession.RelayWelcomePayload
import com.aessam.toursession.SealedSessionEnvelope
import com.aessam.toursession.SessionAuthenticator
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The bridge's island listener for one lane (ADR-081 P1, ADR-083). An island peer connects, the bridge runs the
 * relay lane handshake (its own challenge, the peer's relay proof, a `RelayWelcomePayload` carrying the guide-signed
 * `bridgeAssignment`), then:
 * - realtime/control: the peer is attached to [RelayHub] and receives verified guide frames unchanged;
 * - asset: the bridge serves requested chunks of files it holds; the peer accepts them only for hashes in the
 *   guide's manifest (W6). Chunks are bridge-sealed and never pass through [RelayHub].
 * Peers are refused until the guide has assigned this bridge. Admission is not handled here: it is tunneled to the
 * guide by the existing nearby bridge path.
 */
class RelayLaneServer(
    private val lane: SessionLane,
    private val credential: SessionCredential,
    private val sessionID: UUID,
    private val guideID: UUID,
    private val bridgeID: UUID,
    private val hub: RelayHub,
    /** File holding the asset with this SHA-256, if the bridge has it (asset lane only). */
    private val assetFile: (String) -> File? = { null },
    private val bindAddress: InetAddress = InetAddress.getLoopbackAddress(),
    port: Int = 0,
) : AutoCloseable {
    private val server = ServerSocket(port, 16, bindAddress)
    private val running = AtomicBoolean(true)
    val port: Int get() = server.localPort

    init {
        Thread({ acceptLoop() }, "relay-$lane-accept").apply { isDaemon = true }.start()
    }

    override fun close() {
        running.set(false)
        try { server.close() } catch (error: Exception) { Log.e(TAG, "Relay listener close failed (${error.javaClass.simpleName})") }
    }

    private fun acceptLoop() {
        while (running.get()) {
            val socket = try { server.accept() } catch (error: Exception) {
                if (running.get()) Log.e(TAG, "Relay accept failed (${error.javaClass.simpleName})")
                return
            }
            Thread({ serve(socket) }, "relay-$lane-peer").apply { isDaemon = true }.start()
        }
    }

    private fun serve(socket: Socket) {
        socket.tcpNoDelay = true
        try {
            val (assignmentFrame, generation) = synchronized(hub) { hub.assignmentFrame to hub.assignment?.generation }
            if (assignmentFrame == null || generation == null) throw IllegalStateException("bridge is not assigned by the guide")
            val sealer = SessionFrameSealer(credential)
            val stream = UUID.randomUUID()
            val peer = handshake(socket, sealer, stream, assignmentFrame, generation)
            when (lane) {
                SessionLane.REALTIME, SessionLane.CONTROL -> {
                    val writer = SocketChildWriter(socket, lane)
                    hub.attach(lane, writer)
                    // Island peers send nothing on these lanes except to leave; any read ends the peer.
                    try { socket.getInputStream().read() } finally { hub.detach(lane, writer); writer.close() }
                }
                SessionLane.ASSET -> serveAssets(socket, sealer, stream, peer)
            }
        } catch (error: Exception) {
            if (error !is EOFException) Log.e(TAG, "Relay $lane peer ended (${error.javaClass.simpleName}: ${error.message})")
            closeQuietly(socket)
        }
    }

    /** Bridge side of ADR-083; returns the authenticated peer's participant ID. */
    private fun handshake(socket: Socket, sealer: SessionFrameSealer, stream: UUID, assignmentFrame: ByteArray, generation: Long): UUID {
        val input = socket.getInputStream()
        val output = socket.getOutputStream()
        val challengeNonce = SessionAuthenticator.randomNonce()
        writeFrame(output, sealer.seal(envelope(SessionMessageKind.AUTH_CHALLENGE, 0, AuthChallengePayload(lane, challengeNonce).encode()), stream).encode())
        val opener = SessionFrameOpener(credential)
        val hello = (opener.open(SealedSessionEnvelope.decode(readFrame(input, HELLO_MAXIMUM))) as? SessionFrameOpenResult.Opened)?.envelope
            ?: throw IllegalArgumentException("duplicate relay hello")
        val payload = HelloPayload.decode(hello.payload)
        if (hello.sessionId != sessionID || hello.kind != SessionMessageKind.HELLO || hello.senderId == bridgeID ||
            hello.senderId == guideID || payload.role != SessionRole.GUEST || payload.requestedLane != lane
        ) throw IllegalArgumentException("invalid relay hello")
        val context = RelayLaneContext(sessionID, guideID, RelayHostAdvert(bridgeID, generation), hello.senderId, lane)
        val expected = RelayLaneAuthenticator.guestProof(credential, context, challengeNonce, payload.clientNonce,
            payload.role, payload.platform, payload.capabilities, payload.displayName)
        if (!SessionAuthenticator.securelyMatches(expected, payload.credentialProof)) throw IllegalArgumentException("relay proof was rejected")
        val bridgeNonce = SessionAuthenticator.randomNonce()
        val proof = RelayLaneAuthenticator.bridgeProof(credential, context, challengeNonce, payload.clientNonce, bridgeNonce)
        val welcome = RelayWelcomePayload(lane, bridgeNonce, proof, assignmentFrame)
        writeFrame(output, sealer.seal(envelope(SessionMessageKind.WELCOME, 1, welcome.encode()), stream).encode())
        return hello.senderId
    }

    private fun serveAssets(socket: Socket, sealer: SessionFrameSealer, stream: UUID, peer: UUID) {
        val input = socket.getInputStream()
        val output = socket.getOutputStream()
        val opener = SessionFrameOpener(credential)
        var sequence = 1L
        while (running.get()) {
            val request = (opener.open(SealedSessionEnvelope.decode(readFrame(input, HELLO_MAXIMUM))) as? SessionFrameOpenResult.Opened)?.envelope
                ?: continue
            if (request.senderId != peer || request.kind != SessionMessageKind.ASSET_REQUEST) throw IllegalArgumentException("unexpected asset frame")
            val wanted = AssetRequestPayload.decode(request.payload)
            val file = assetFile(wanted.sha256) ?: throw IllegalStateException("bridge does not hold ${wanted.sha256.take(12)}")
            val length = file.length()
            if (wanted.offset < 0 || wanted.offset >= length) throw IllegalArgumentException("asset offset out of range")
            val count = minOf(CHUNK_SIZE.toLong(), length - wanted.offset).toInt()
            val bytes = ByteArray(count)
            RandomAccessFile(file, "r").use { it.seek(wanted.offset); it.readFully(bytes) }
            sequence += 1
            val chunk = AssetChunkPayload(wanted.sha256, wanted.offset, length, bytes)
            writeFrame(output, sealer.seal(envelope(SessionMessageKind.ASSET_CHUNK, sequence, chunk.encode()), stream).encode())
        }
    }

    private fun envelope(kind: SessionMessageKind, sequence: Long, payload: ByteArray) = SessionEnvelope(
        lane = kind.requiredLane, kind = kind, sequence = sequence, sessionId = sessionID, senderId = bridgeID, payload = payload,
    )

    /**
     * One island peer's outbound side (ADR-039). Frames queue in a bounded writer drained on its own thread with a
     * send timeout, so a stalled peer never blocks RelayHub (which calls enqueue under its lock) or other peers; on
     * overflow or timeout the peer is disconnected and the hub drops it at the next frame.
     */
    private class SocketChildWriter(private val socket: Socket, lane: SessionLane) : RelayChildWriter {
        @Volatile private var failed = false
        private val writer = BoundedSocketFrameWriter(
            socket = socket,
            generation = 0,
            label = "relay-$lane-peer-writer",
            capacity = if (lane == SessionLane.CONTROL) 64 else 8,
            overflowPolicy = SocketFrameOverflowPolicy.DISCONNECT,
            sendTimeoutMillis = 2_000,
        ) { _, _ ->
            failed = true
            closeQuietly(socket)
        }

        override fun enqueue(frame: ByteArray): Boolean {
            if (failed) return false
            writer.enqueue(frame)
            return !failed
        }

        override fun close() {
            failed = true
            writer.close()
            closeQuietly(socket)
        }
    }

    companion object {
        private const val TAG = "RelayLaneServer"
        const val HELLO_MAXIMUM = 65_536
        const val CHUNK_SIZE = 60 * 1024

        fun writeFrame(output: OutputStream, data: ByteArray) {
            synchronized(output) {
                output.write(ByteBuffer.allocate(4).putInt(data.size).array())
                output.write(data)
                output.flush()
            }
        }

        fun readFrame(input: InputStream, maximum: Int): ByteArray {
            val length = ByteBuffer.wrap(readExact(input, 4)).int
            require(length in 1..maximum) { "invalid frame length $length" }
            return readExact(input, length)
        }

        private fun readExact(input: InputStream, count: Int): ByteArray {
            val bytes = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val received = input.read(bytes, offset, count - offset)
                if (received < 0) throw EOFException("socket closed")
                offset += received
            }
            return bytes
        }

        private fun closeQuietly(socket: Socket) {
            try { socket.close() } catch (error: Exception) { Log.e(TAG, "Relay socket close failed (${error.javaClass.simpleName})") }
        }
    }
}
