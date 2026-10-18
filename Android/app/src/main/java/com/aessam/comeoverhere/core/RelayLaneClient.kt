package com.aessam.comeoverhere.core

import com.aessam.toursession.AuthChallengePayload
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.HelloPayload
import com.aessam.toursession.ParticipantPlatform
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
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/** A far guest's lanes go through this island bridge instead of the guide (ADR-081 P3). */
data class RelayRoute(val host: RelayHostAdvert, val guideID: UUID)

/**
 * Far-guest side of the ADR-083 relay lane handshake. The challenge and welcome are bridge-sealed (not GOS1);
 * the welcome must carry the guide-signed assignment naming exactly [RelayRoute.host]. After it, every frame on
 * realtime/control is a guide frame the guest verifies with its pinned key as usual.
 */
object RelayLaneClient {
    /** Raised when the bridge's proof or assignment does not match; rediscover the island, never a credential failure. */
    class RelayRouteRejectedException(message: String, cause: Throwable? = null) : IllegalStateException(message, cause)

    fun handshake(
        input: InputStream,
        output: OutputStream,
        route: RelayRoute,
        lane: SessionLane,
        credential: SessionCredential,
        sessionID: UUID,
        participantID: UUID,
        platform: ParticipantPlatform,
        capabilities: Long,
        displayName: String,
        verifier: GuideFrameVerifier,
        readFrame: (InputStream) -> ByteArray,
        writeFrame: (OutputStream, ByteArray) -> Unit,
        nowMilliseconds: Long = System.currentTimeMillis(),
    ): BridgeAssignmentPayload {
        val opener = SessionFrameOpener(credential)
        fun open(frame: ByteArray): SessionEnvelope =
            (opener.open(SealedSessionEnvelope.decode(frame)) as? SessionFrameOpenResult.Opened)?.envelope
                ?: throw IllegalArgumentException("duplicate relay handshake frame")
        val challengeEnvelope = open(readFrame(input))
        if (challengeEnvelope.sessionId != sessionID || challengeEnvelope.kind != SessionMessageKind.AUTH_CHALLENGE ||
            challengeEnvelope.senderId != route.host.hostID) {
            throw RelayRouteRejectedException("unexpected relay challenge")
        }
        val challenge = AuthChallengePayload.decode(challengeEnvelope.payload)
        if (challenge.requestedLane != lane) throw IllegalArgumentException("relay challenge used the wrong lane")
        val context = RelayLaneContext(sessionID, route.guideID, route.host, participantID, lane)
        val clientNonce = SessionAuthenticator.randomNonce()
        val proof = RelayLaneAuthenticator.guestProof(credential, context, challenge.challengeNonce, clientNonce,
            SessionRole.GUEST, platform, capabilities, displayName)
        val hello = HelloPayload(SessionRole.GUEST, platform, capabilities, displayName, lane, clientNonce, proof)
        writeFrame(output, SessionFrameSealer(credential).seal(SessionEnvelope(lane = SessionLane.CONTROL,
            kind = SessionMessageKind.HELLO, sequence = 0, sessionId = sessionID, senderId = participantID,
            payload = hello.encode()), UUID.randomUUID()).encode())
        val welcomeEnvelope = open(readFrame(input))
        if (welcomeEnvelope.sessionId != sessionID || welcomeEnvelope.kind != SessionMessageKind.WELCOME ||
            welcomeEnvelope.senderId != route.host.hostID) {
            throw RelayRouteRejectedException("unexpected relay welcome")
        }
        return try {
            RelayWelcomePayload.decode(welcomeEnvelope.payload).verify(credential, context, challenge.challengeNonce,
                clientNonce, verifier, nowMilliseconds)
        } catch (error: Exception) {
            throw RelayRouteRejectedException("relay welcome rejected (${error.message})", error)
        }
    }
}
