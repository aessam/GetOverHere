package com.aessam.toursession

import java.math.BigInteger
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class RoomAdmissionV2Test {
    private val secret = "23456789AB"

    @Test fun roundtripBindsMediaCredentialAndSigningIdentity() {
        listOf(null, "1234", "My-Tour!42", "a".repeat(64)).forEach { code ->
            val frame = TourSessionFixtures.encryptedRealtimeFixture()
            val signer = GuideFrameSigner(frame.sessionId, frame.senderId)
            val guide = RoomAdmissionV2.Guide(frame.sessionId, RoomAccessPolicy(frame.sessionId, code), signer)
            val guest = RoomAdmissionV2.Guest(guide.challenge, frame.sessionId, frame.senderId, code)
            val reply = guide.reply(guest.request, secret)
            val admitted = guest.open(reply)
            assertEquals(103, guide.challenge.size)
            assertEquals(97, guest.request.size)
            assertEquals(183, reply.size)
            assertEquals(secret, admitted.mediaSecret)
            assertArrayEquals(signer.publicKey, admitted.guideIdentity.publicKey)
            assertEquals(frame.sessionId, admitted.guideIdentity.sessionId)
            assertEquals(frame.senderId, admitted.guideIdentity.guideId)
            assertFalse(admitted.toString().contains(secret))
            val verifier = GuideFrameVerifier(admitted.guideIdentity.publicKey, frame.sessionId, frame.senderId)
            assertArrayEquals(frame.encode(), verifier.verify(signer.sign(frame).encode()).encode())
        }
    }

    @Test fun messagesRejectTruncationTrailingBytesAndEveryReplyMutation() {
        val session = UUID.randomUUID()
        val guideId = UUID.randomUUID()
        val signer = GuideFrameSigner(session, guideId)
        val guide = RoomAdmissionV2.Guide(session, RoomAccessPolicy(session, null), signer)
        val guest = RoomAdmissionV2.Guest(guide.challenge, session, guideId, null)
        val reply = guide.reply(guest.request, secret)
        repeat(RoomAdmissionV2.CHALLENGE_SIZE) { length ->
            assertThrows(Exception::class.java) { RoomAdmissionV2.Guest(guide.challenge.copyOf(length), session, guideId, null) }
        }
        assertThrows(Exception::class.java) { RoomAdmissionV2.Guest(guide.challenge + byteArrayOf(0), session, guideId, null) }
        repeat(RoomAdmissionV2.REQUEST_SIZE) { length ->
            assertThrows(Exception::class.java) { guide.reply(guest.request.copyOf(length), secret) }
        }
        assertThrows(Exception::class.java) { guide.reply(guest.request + byteArrayOf(0), secret) }
        repeat(RoomAdmissionV2.REPLY_SIZE) { length ->
            assertThrows(Exception::class.java) { guest.open(reply.copyOf(length)) }
        }
        assertThrows(Exception::class.java) { guest.open(reply + byteArrayOf(0)) }
        reply.indices.forEach { index ->
            val changed = reply.copyOf().apply { this[index] = (this[index].toInt() xor 1).toByte() }
            assertThrows(Exception::class.java) { guest.open(changed) }
        }
        listOf(0, 4, 21, 38).forEach { index ->
            val changed = guide.challenge.apply { this[index] = if (index == 4) 1 else -1 }
            assertThrows(Exception::class.java) { RoomAdmissionV2.Guest(changed, session, guideId, null) }
        }
    }

    @Test fun rejectsDowngradeWrongCodeAndReplayedTranscript() {
        val session = UUID.randomUUID()
        val guideId = UUID.randomUUID()
        val policy = RoomAccessPolicy(session, "1234")
        val signer = GuideFrameSigner(session, guideId)
        val guide = RoomAdmissionV2.Guide(session, policy, signer)
        val guest = RoomAdmissionV2.Guest(guide.challenge, session, guideId, "1234")
        val wrong = RoomAdmissionV2.Guest(guide.challenge, session, guideId, "5678")
        assertThrows(Exception::class.java) { guide.reply(wrong.request, secret) }
        assertThrows(Exception::class.java) { RoomAdmissionV2.Guest(guide.challenge, session, guideId, null) }
        assertThrows(Exception::class.java) { RoomAdmissionV2.Guest(guide.challenge, UUID.randomUUID(), guideId, "1234") }
        val next = RoomAdmissionV2.Guide(session, policy, signer)
        assertThrows(Exception::class.java) { next.reply(guest.request, secret) }
        val otherGuest = RoomAdmissionV2.Guest(guide.challenge, session, guideId, "1234")
        val reply = guide.reply(guest.request, secret)
        assertThrows(Exception::class.java) { otherGuest.open(reply) }
        val v1 = RoomAdmission.Guide(session, policy)
        val versionError = assertThrows(RoomAdmissionV2Exception::class.java) {
            RoomAdmissionV2.Guest(v1.challenge, session, guideId, "1234")
        }
        assertEquals(RoomAdmissionV2Exception.Reason.INCOMPATIBLE_VERSION, versionError.reason)
        assertThrows(Exception::class.java) { RoomAdmission.Guest(guide.challenge, session, "1234") }
        val open = RoomAdmissionV2.Guide(session, RoomAccessPolicy(session, null), signer)
        assertThrows(Exception::class.java) { RoomAdmissionV2.Guest(open.challenge, session, guideId, "1234") }
    }

    @Test fun rejectsWrongSelectedGuideAndSignerSession() {
        val session = UUID.randomUUID()
        val signer = GuideFrameSigner(session, UUID.randomUUID())
        val policy = RoomAccessPolicy(session, null)
        assertThrows(Exception::class.java) { RoomAdmissionV2.Guide(UUID.randomUUID(), policy, signer) }
        val guide = RoomAdmissionV2.Guide(session, policy, signer)
        val guest = RoomAdmissionV2.Guest(guide.challenge, session, UUID.randomUUID(), null)
        val wrongGuide = assertThrows(RoomAdmissionV2Exception::class.java) { guest.open(guide.reply(guest.request, secret)) }
        assertEquals(RoomAdmissionV2Exception.Reason.WRONG_GUIDE, wrongGuide.reason)
        listOf("", "23456789A", "23456789ABC", "23456789A0", "23456789aB", "23456789é").forEach { invalid ->
            assertThrows(Exception::class.java) { guide.reply(guest.request, invalid) }
        }
    }

    @Test fun possessionProofBindsEveryCredentialByteAndFreshTranscript() {
        val session = UUID.randomUUID()
        val guideId = UUID.randomUUID()
        val signer = GuideFrameSigner(session, guideId)
        val transcript = "test-only-fresh-transcript".toByteArray()
        val body = secret.toByteArray() + RoomAdmission.identity(guideId) + signer.publicKey
        val proof = signer.admissionProof(transcript, body)
        val plaintext = body + proof
        val admitted = RoomAdmissionV2.validateCredentials(plaintext, transcript, session, guideId)
        assertArrayEquals(signer.publicKey, admitted.guideIdentity.publicKey)
        plaintext.indices.forEach { index ->
            val changed = plaintext.copyOf().apply { this[index] = (this[index].toInt() xor 1).toByte() }
            assertThrows(Exception::class.java) { RoomAdmissionV2.validateCredentials(changed, transcript, session, guideId) }
        }
        val high = (GuideSignatureEncoding.order - BigInteger(1, proof.copyOfRange(32, 64))).toByteArray()
        val highS = if (high.size >= 32) high.takeLast(32).toByteArray() else ByteArray(32 - high.size) + high
        listOf(plaintext.copyOf(154), plaintext + byteArrayOf(0), plaintext.copyOf(123) + highS).forEach { changed ->
            assertThrows(Exception::class.java) { RoomAdmissionV2.validateCredentials(changed, transcript, session, guideId) }
        }
        assertThrows(Exception::class.java) {
            RoomAdmissionV2.validateCredentials(plaintext, transcript + byteArrayOf(0), session, guideId)
        }
    }

    @Test fun pinSurvivesReconnectAndRejectsAnyIdentityChangeUntilExplicitEnd() {
        val session = UUID.randomUUID()
        val guideId = UUID.randomUUID()
        val signer = GuideFrameSigner(session, guideId)
        fun admit(signer: GuideFrameSigner): AdmittedGuideIdentity {
            val guide = RoomAdmissionV2.Guide(signer.sessionId, RoomAccessPolicy(signer.sessionId, null), signer)
            val guest = RoomAdmissionV2.Guest(guide.challenge, signer.sessionId, signer.guideId, null)
            return guest.open(guide.reply(guest.request, secret)).guideIdentity
        }
        val pin = SessionGuidePin()
        val original = admit(signer)
        pin.accept(original)
        pin.accept(admit(signer))
        listOf(GuideFrameSigner(session, guideId), GuideFrameSigner(UUID.randomUUID(), guideId),
            GuideFrameSigner(session, UUID.randomUUID())).forEach { replacement ->
            val candidate = admit(replacement)
            assertThrows(Exception::class.java) { pin.accept(candidate) }
            assertSame(original, pin.identity)
        }
        pin.endSession()
        assertNull(pin.identity)
        pin.accept(admit(GuideFrameSigner(UUID.randomUUID(), UUID.randomUUID())))
        assertNotNull(pin.identity)
    }

    @Test fun returnedArraysCannotMutateInFlightAdmissionOrPinnedKey() {
        val session = UUID.randomUUID()
        val guideId = UUID.randomUUID()
        val signer = GuideFrameSigner(session, guideId)
        val guide = RoomAdmissionV2.Guide(session, RoomAccessPolicy(session, null), signer)
        guide.challenge.fill(0)
        val guest = RoomAdmissionV2.Guest(guide.challenge, session, guideId, null)
        guest.request.fill(0)
        val admitted = guest.open(guide.reply(guest.request, secret))
        admitted.guideIdentity.publicKey.fill(0)
        assertArrayEquals(signer.publicKey, admitted.guideIdentity.publicKey)
    }
}
