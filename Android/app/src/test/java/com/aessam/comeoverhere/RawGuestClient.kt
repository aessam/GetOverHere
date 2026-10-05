package com.aessam.comeoverhere

import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.ParticipantPlatform
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
import com.aessam.toursession.WelcomePayload
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID

/**
 * A guest that speaks the GOH2 handshake but is otherwise inert: it never reads unless asked and
 * stamps whatever sender ID the test gives it. The production transport can emulate neither (it
 * always reads, and always stamps its own participant ID), which the FND-12 stalled-peer and
 * forged-sender tests need. `authenticate` is a port of
 * `LocalAuthenticatedSessionTransport.authenticateGuide`.
 */
internal class RawGuestClient(port: Int, receiveBufferSize: Int? = null) : AutoCloseable {
    private val socket = Socket().apply {
        // The receive buffer must be set before connect so the window is advertised at SYN time.
        if (receiveBufferSize != null) this.receiveBufferSize = receiveBufferSize
        tcpNoDelay = true
        connect(InetSocketAddress("127.0.0.1", port), 5_000)
    }
    private val input: InputStream = socket.getInputStream()
    private val output: OutputStream = socket.getOutputStream()

    /** Completes the sealed challenge/hello/welcome handshake and returns the guide's sender ID. */
    fun authenticate(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
        lane: SessionLane,
    ): UUID {
        val guideOpener = SessionFrameOpener(credential)
        val challengeEnvelope = openFrame(readFrame(), guideOpener)
            ?: throw IllegalArgumentException("duplicate authentication challenge")
        if (
            challengeEnvelope.sessionId != sessionID ||
            challengeEnvelope.kind != SessionMessageKind.AUTH_CHALLENGE ||
            challengeEnvelope.lane != SessionLane.CONTROL ||
            challengeEnvelope.senderId == participantID
        ) {
            throw IllegalArgumentException("unexpected authentication challenge")
        }
        val challenge = AuthChallengePayload.decode(challengeEnvelope.payload)
        if (challenge.requestedLane != lane) {
            throw IllegalArgumentException("authentication challenge used the wrong lane")
        }
        val clientNonce = SessionAuthenticator.randomNonce()
        val proof = SessionAuthenticator.guestProof(
            credential,
            sessionID,
            challengeEnvelope.senderId,
            participantID,
            lane,
            challenge.challengeNonce,
            clientNonce,
            SessionRole.GUEST,
            platform,
            0L,
            displayName,
        )
        val hello = HelloPayload(
            SessionRole.GUEST,
            platform,
            0,
            displayName,
            lane,
            clientNonce,
            proof,
        )
        val helloEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.HELLO,
            sequence = 0,
            sessionId = sessionID,
            senderId = participantID,
            payload = hello.encode(),
        )
        send(helloEnvelope, SessionFrameSealer(credential), UUID.randomUUID())
        val welcomeEnvelope = openFrame(readFrame(), guideOpener)
            ?: throw IllegalArgumentException("duplicate welcome envelope")
        if (
            welcomeEnvelope.sessionId != sessionID ||
            welcomeEnvelope.kind != SessionMessageKind.WELCOME ||
            welcomeEnvelope.lane != SessionLane.CONTROL ||
            welcomeEnvelope.senderId != challengeEnvelope.senderId
        ) {
            throw IllegalArgumentException("unexpected welcome envelope")
        }
        val welcome = WelcomePayload.decode(welcomeEnvelope.payload)
        if (welcome.requestedLane != lane) {
            throw IllegalArgumentException("welcome used the wrong lane")
        }
        val expectedProof = SessionAuthenticator.guideProof(
            credential,
            sessionID,
            challengeEnvelope.senderId,
            participantID,
            lane,
            challenge.challengeNonce,
            clientNonce,
            welcome.guideNonce,
        )
        if (!SessionAuthenticator.securelyMatches(expectedProof, welcome.credentialProof)) {
            throw IllegalArgumentException("guide credential proof was rejected")
        }
        return challengeEnvelope.senderId
    }

    /** Seals and writes one length-prefixed frame exactly as the production writer does. */
    fun send(envelope: SessionEnvelope, sealer: SessionFrameSealer, streamID: UUID) {
        val data = sealer.seal(envelope, streamID).encode()
        require(data.isNotEmpty())
        synchronized(output) {
            output.write(ByteBuffer.allocate(4).putInt(data.size).array())
            output.write(data)
            output.flush()
        }
    }

    /** Blocking read of one length-prefixed frame; throws [EOFException] once the guide closes. */
    fun readFrame(maximumSize: Int = 1_048_576): ByteArray {
        val length = ByteBuffer.wrap(readExact(4)).int
        if (length <= 0 || length > maximumSize) {
            throw IllegalArgumentException("invalid frame length $length")
        }
        return readExact(length)
    }

    override fun close() {
        socket.close()
    }

    private fun readExact(count: Int): ByteArray {
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

    private fun openFrame(frame: ByteArray, opener: SessionFrameOpener): SessionEnvelope? =
        when (val result = opener.open(SealedSessionEnvelope.decode(frame))) {
            is SessionFrameOpenResult.Opened -> result.envelope
            is SessionFrameOpenResult.Duplicate -> null
        }
}
