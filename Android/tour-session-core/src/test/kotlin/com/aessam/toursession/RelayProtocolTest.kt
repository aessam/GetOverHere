package com.aessam.toursession

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors RelayProtocolTests.swift (ADR-081); the pinned fixture must stay identical on both platforms. */
class RelayProtocolTest {
    private val fixture = "assignment=00000000000000076f1c5c6a0000400080000000000000a1020000018bcfe5687b016f1c5c6a0000400080000000000000a2|upstream=016f1c5c6a0000400080000000000000b10200000005474f483201|decisions=forward,duplicate,conflict,expired,forward,forward,forward|snapshots=bearingSnapshot:4,presentationSnapshot:5|guestProof=bcccd0792e4a8622103054af1b2b6276d2a898017f4e809b471419c4ee401ba0|bridgeProof=299bc53d580abcd51daacc95d9d643e92a725a260d7478913a63fbbb7c5de8b3|welcome=0233333333333333333333333333333333299bc53d580abcd51daacc95d9d643e92a725a260d7478913a63fbbb7c5de8b300000004474f5331"

    @Test fun pinnedFixture() = assertEquals(fixture, TourSessionFixtures.relayFixture())

    @Test fun bridgeAssignmentRoundtripAndRejections() {
        val value = BridgeAssignmentPayload(-1L, UUID.randomUUID(), ParticipantPlatform.IOS, 1, listOf(UUID.randomUUID(), UUID.randomUUID()))
        assertEquals(value, BridgeAssignmentPayload.decode(value.encode()))
        assertThrows(RelayProtocolException::class.java) {
            BridgeAssignmentPayload(1, UUID.randomUUID(), ParticipantPlatform.IOS, 1, List(3) { UUID.randomUUID() })
        }
        val bytes = value.encode().also { it[24] = 3 }
        assertThrows(RelayProtocolException::class.java) { BridgeAssignmentPayload.decode(bytes) }
        assertThrows(RelayProtocolException::class.java) { BridgeAssignmentPayload.decode(value.encode() + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { BridgeAssignmentPayload.decode(value.encode().copyOf(value.encode().size - 1)) }
        assertEquals(SessionLane.CONTROL, SessionMessageKind.BRIDGE_ASSIGNMENT.requiredLane)
        assertEquals(1L shl 5, SessionCapability.RELAY_HOST.bit)
    }

    @Test fun upstreamRecordRoundtripAndRejections() {
        val value = RelayUpstreamRecord(UUID.randomUUID(), SessionLane.ASSET, ByteArray(300) { 7 })
        assertEquals(value, RelayUpstreamRecord.decode(value.encode()))
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord.decode(value.encode().also { it[0] = 2 }) }
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord.decode(value.encode().also { it[17] = 9 }) }
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord(UUID.randomUUID(), SessionLane.CONTROL, ByteArray(65_537)) }
        assertThrows(RelayProtocolException::class.java) { RelayUpstreamRecord.decode(value.encode() + byteArrayOf(0)) }
    }

    private class Guide {
        val session: UUID = UUID.randomUUID(); val id: UUID = UUID.randomUUID(); val stream: UUID = UUID.randomUUID()
        val signer = GuideFrameSigner(session, id)
        fun verifier() = GuideFrameVerifier(signer.publicKey, session, id)
        fun frame(kind: SessionMessageKind, sequence: Long, by: GuideFrameSigner = signer): ByteArray =
            by.sign(SealedSessionEnvelope(lane = kind.requiredLane, kind = kind, sequence = sequence, sessionId = session,
                senderId = id, streamId = stream, sealedPayload = ByteArray(16))).encode()
    }

    @Test fun forwarderWindowForgetsOldestIdentity() {
        val guide = Guide()
        val forwarder = RelayForwarder(guide.verifier())
        for (sequence in 1..RelayForwarder.WINDOW_SIZE + 1L) {
            assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(guide.frame(SessionMessageKind.HEARTBEAT, sequence), 0, 0))
        }
        assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(guide.frame(SessionMessageKind.HEARTBEAT, 1), 0, 0))
        assertEquals(RelayForwarder.Decision.CONFLICT,
            forwarder.admit(guide.frame(SessionMessageKind.HEARTBEAT, RelayForwarder.WINDOW_SIZE.toLong()), 0, 0))
        assertTrue(forwarder.snapshotFrames.isEmpty())
    }

    /** A frame not signed by the pinned guide changes nothing: no pre-emption, no cache poisoning. */
    @Test fun unverifiedFramesAreRejectedBeforeAnyState() {
        val guide = Guide()
        val member = GuideFrameSigner(guide.session, guide.id)
        val forwarder = RelayForwarder(guide.verifier())
        val forged = guide.frame(SessionMessageKind.PRESENTATION_SNAPSHOT, 9, by = member)
        assertThrows(Exception::class.java) { forwarder.admit(forged, 0, 0) }
        assertTrue(forwarder.snapshotFrames.isEmpty())
        val real = guide.frame(SessionMessageKind.PRESENTATION_SNAPSHOT, 9)
        assertEquals(RelayForwarder.Decision.FORWARD, forwarder.admit(real, 0, 0))
        assertEquals(1, forwarder.snapshotFrames.size)
        val tampered = real.copyOf().also { it[it.size - 70] = (it[it.size - 70].toInt() xor 1).toByte() }
        assertThrows(Exception::class.java) { forwarder.admit(tampered, 0, 0) }
    }

    /** Mirrors RelayProtocolTests.peerAssetAcceptance (W6). */
    @Test fun peerAssetAcceptance() {
        val manifest = TourPackArchive.read(TourSessionFixtures.tourPackFixture()).first.manifest
        val file = manifest.assets[0]
        fun chunk(hash: String, offset: Long, count: Int, total: Long = file.byteLength) =
            AssetChunkPayload(hash, offset, total, ByteArray(count))
        assertTrue(PeerAssetAcceptance.accepts(chunk(file.sha256, 0, file.byteLength.toInt()), manifest))
        assertTrue(PeerAssetAcceptance.accepts(chunk(file.sha256, 4, 3), manifest))
        assertTrue(!PeerAssetAcceptance.accepts(chunk("a".repeat(64), 0, 1, total = 1), manifest))
        assertTrue(!PeerAssetAcceptance.accepts(chunk(file.sha256, 0, 1, total = file.byteLength + 1), manifest))
        assertTrue(!PeerAssetAcceptance.accepts(chunk(file.sha256, 0, 0), manifest))
    }

    /** Mirrors RelayProtocolTests.relayWelcomeVerification (W4, ADR-083). */
    @Test fun relayWelcomeVerification() {
        val guide = Guide()
        val credential = SessionCredential.derive("23456789AB", guide.session)
        val host = RelayHostAdvert(UUID.randomUUID(), 3)
        val context = RelayLaneContext(guide.session, guide.id, host, UUID.randomUUID(), SessionLane.CONTROL)
        val challenge = SessionAuthenticator.randomNonce(); val client = SessionAuthenticator.randomNonce()
        val bridgeNonce = SessionAuthenticator.randomNonce()
        val sealer = SessionFrameSealer(credential)
        var sequence = 0L
        fun assignmentFrame(bridge: UUID = host.hostID, generation: Long = 3, expires: Long = 10_000,
                            kind: SessionMessageKind = SessionMessageKind.BRIDGE_ASSIGNMENT, signer: GuideFrameSigner = guide.signer): ByteArray {
            val payload = BridgeAssignmentPayload(generation, bridge, ParticipantPlatform.ANDROID, expires, emptyList()).encode()
            sequence += 1 // the sealer requires increasing sequences per stream
            val envelope = SessionEnvelope(lane = SessionLane.CONTROL, kind = kind, sequence = sequence,
                sessionId = guide.session, senderId = guide.id, payload = payload)
            return signer.sign(sealer.seal(envelope, guide.stream)).encode()
        }
        fun welcome(frame: ByteArray, proofCredential: SessionCredential = credential, lane: SessionLane = SessionLane.CONTROL) =
            RelayWelcomePayload(lane, bridgeNonce,
                RelayLaneAuthenticator.bridgeProof(proofCredential, context, challenge, client, bridgeNonce), frame)
        fun verify(value: RelayWelcomePayload) =
            RelayWelcomePayload.decode(value.encode()).verify(credential, context, challenge, client, guide.verifier(), 5_000)
        fun reason(block: () -> Unit) = assertThrows(RelayProtocolException::class.java) { block() }.message

        assertEquals(host.hostID, verify(welcome(assignmentFrame())).bridgeID)
        val outsider = SessionCredential.derive("ZZZZ9999AB", guide.session)
        assertTrue(reason { verify(welcome(assignmentFrame(), proofCredential = outsider)) }!!.contains("relayProofMismatch"))
        assertTrue(reason { verify(welcome(assignmentFrame(), lane = SessionLane.ASSET)) }!!.contains("wrongLane"))
        assertTrue(reason { verify(welcome(assignmentFrame(bridge = UUID.randomUUID()))) }!!.contains("assignmentNamesAnotherHost"))
        assertTrue(reason { verify(welcome(assignmentFrame(generation = 4))) }!!.contains("assignmentNamesAnotherHost"))
        assertTrue(reason { verify(welcome(assignmentFrame(expires = 5_000))) }!!.contains("assignmentExpired"))
        assertTrue(reason { verify(welcome(assignmentFrame(kind = SessionMessageKind.HEARTBEAT))) }!!.contains("notBridgeAssignment"))
        val member = GuideFrameSigner(guide.session, guide.id)
        assertThrows(Exception::class.java) { verify(welcome(assignmentFrame(signer = member))) }

        val direct = SessionAuthenticator.guestProof(credential, guide.session, guide.id, context.participantID, SessionLane.CONTROL,
            challenge, client, SessionRole.GUEST, ParticipantPlatform.IOS, 0, "G")
        val relay = RelayLaneAuthenticator.guestProof(credential, context, challenge, client, SessionRole.GUEST, ParticipantPlatform.IOS, 0, "G")
        assertTrue("relay proofs use their own domain", !direct.contentEquals(relay))
    }

    /** Mirrors RelayProtocolTests.bridgeAuthority (P2). */
    @Test fun bridgeAuthority() = assertEquals("iosOnly=none|androidNoRelay=none|firstBridge=g1:03:63000:|noChange=none|standbyJoins=g2:03:65000:04|renew=g2:03:100000:04|bridgeLeft=g3:04:101000:|nobody=none", TourSessionFixtures.bridgeAuthorityFixture())
}
