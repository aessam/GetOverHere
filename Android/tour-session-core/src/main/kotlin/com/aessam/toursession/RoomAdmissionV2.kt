package com.aessam.toursession

import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Verified session signing-key possession, not verified human identity. Never construct from discovery. */
class AdmittedGuideIdentity internal constructor(val sessionId: UUID, val guideId: UUID, publicKey: ByteArray) {
    private val keyBytes = publicKey.copyOf()
    val publicKey: ByteArray get() = keyBytes.copyOf()
    internal fun matches(other: AdmittedGuideIdentity): Boolean =
        sessionId == other.sessionId && guideId == other.guideId && keyBytes.contentEquals(other.keyBytes)
}

/** Media credential is not the editable room code; keep it out of UI, diagnostics and persistence. */
class AdmittedRoomCredentials internal constructor(val mediaSecret: String, val guideIdentity: AdmittedGuideIdentity) {
    override fun toString(): String = "AdmittedRoomCredentials(<redacted>)"
}

class RoomAdmissionV2Exception(val reason: Reason) : IllegalArgumentException(when (reason) {
    Reason.INCOMPATIBLE_VERSION -> "This room requires a compatible app version. Update and try again."
    Reason.WRONG_GUIDE -> "The room admission did not come from the selected guide."
    Reason.GUIDE_CHANGED -> "The guide identity changed. End this session before joining again."
}) {
    enum class Reason { INCOMPATIBLE_VERSION, WRONG_GUIDE, GUIDE_CHANGED }
}

/** Session-owner confined. Preserve across reconnects; clear only on explicit leave/end. */
class SessionGuidePin {
    var identity: AdmittedGuideIdentity? = null
        private set

    fun accept(admitted: AdmittedGuideIdentity) {
        val pinned = identity
        if (pinned == null) identity = admitted
        else if (!pinned.matches(admitted)) throw RoomAdmissionV2Exception(RoomAdmissionV2Exception.Reason.GUIDE_CHANGED)
    }

    fun endSession() { identity = null }
}

/** GOHR v2, strict 103/97/183-byte messages. Open first contact is TOFU, not verified identity.
 * ECDH/HMAC, the encrypted credential reply and guide signature all bind the fresh transcript.
 */
object RoomAdmissionV2 {
    const val PORT = RoomAdmission.PORT
    const val CHALLENGE_SIZE = 103
    const val REQUEST_SIZE = 97
    const val REPLY_SIZE = 183
    private val magic = byteArrayOf(0x47, 0x4f, 0x48, 0x52, 2)
    private const val DERIVATION_DOMAIN = "GetOverHere/room-admission/v2"
    internal val PROOF_DOMAIN = "GetOverHere/room-admission-guide/v2\u0000".toByteArray(Charsets.US_ASCII)

    class Guide(sessionId: UUID, private val policy: RoomAccessPolicy, private val signer: GuideFrameSigner) {
        private val key = RoomAdmission.newKey()
        private val challengeBytes: ByteArray
        val challenge: ByteArray get() = challengeBytes.copyOf()

        init {
            if (signer.sessionId != sessionId) throw RoomAdmissionV2Exception(RoomAdmissionV2Exception.Reason.WRONG_GUIDE)
            challengeBytes = magic + RoomAdmission.identity(sessionId) + byteArrayOf(if (policy.isLocked) 1 else 0) +
                SessionAuthenticator.randomNonce() + RoomAdmission.publicBytes(key)
        }

        fun reply(request: ByteArray, mediaSecret: String): ByteArray {
            val mediaBytes = mediaSecret.toByteArray(Charsets.UTF_8)
            require(request.size == REQUEST_SIZE && validMediaSecret(mediaBytes)) { "Invalid room admission message" }
            val publicKey = request.copyOfRange(0, 65)
            val transcript = challengeBytes + publicKey
            val sharedKey = RoomAdmission.derive(key, publicKey, policy.secret, transcript, DERIVATION_DOMAIN)
            require(SessionAuthenticator.securelyMatches(
                SessionAuthenticator.hmac(sharedKey, transcript), request.copyOfRange(65, 97),
            )) { "Room admission failed. Check the code and try again." }
            val credentials = mediaBytes + RoomAdmission.identity(signer.guideId) + signer.publicKey
            val plaintext = credentials + signer.admissionProof(transcript, credentials)
            val nonce = SessionAuthenticator.randomNonce().copyOf(12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sharedKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(transcript)
            return (nonce + cipher.doFinal(plaintext)).also { check(it.size == REPLY_SIZE) }
        }
    }

    class Guest(challenge: ByteArray, private val sessionId: UUID, private val expectedGuideId: UUID, code: String?) {
        private val requestBytes: ByteArray
        val request: ByteArray get() = requestBytes.copyOf()
        private val key: ByteArray
        private val transcript: ByteArray

        init {
            val bytes = challenge.copyOf()
            require(bytes.size == CHALLENGE_SIZE && bytes.copyOfRange(0, 4).contentEquals(magic.copyOf(4))) {
                "Invalid room admission message"
            }
            if (bytes[4] != 2.toByte()) throw RoomAdmissionV2Exception(RoomAdmissionV2Exception.Reason.INCOMPATIBLE_VERSION)
            require(bytes.copyOfRange(0, 21).contentEquals(magic + RoomAdmission.identity(sessionId)) &&
                bytes[21].toInt() in 0..1) { "Invalid room admission message" }
            val locked = bytes[21].toInt() == 1
            if (locked && code == null) throw RoomAdmissionException("This room is locked. Ask the guide for the room code.")
            if (!locked && code != null) throw RoomAdmissionException("Room access changed. Select the room again.")
            val policy = RoomAccessPolicy(sessionId, code)
            val ephemeral = RoomAdmission.newKey()
            val publicKey = RoomAdmission.publicBytes(ephemeral)
            transcript = bytes + publicKey
            key = RoomAdmission.derive(ephemeral, bytes.copyOfRange(38, 103), policy.secret, transcript, DERIVATION_DOMAIN)
            requestBytes = publicKey + SessionAuthenticator.hmac(key, transcript)
        }

        fun open(reply: ByteArray): AdmittedRoomCredentials {
            val bytes = reply.copyOf()
            require(bytes.size == REPLY_SIZE) { "Invalid room admission reply" }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, bytes.copyOf(12)))
            cipher.updateAAD(transcript)
            return validateCredentials(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), transcript, sessionId, expectedGuideId)
        }
    }

    internal fun validateCredentials(plaintext: ByteArray, transcript: ByteArray, sessionId: UUID,
        expectedGuideId: UUID): AdmittedRoomCredentials {
        require(plaintext.size == 155 && validMediaSecret(plaintext.copyOf(10))) { "Invalid admitted credentials" }
        if (!plaintext.copyOfRange(10, 26).contentEquals(RoomAdmission.identity(expectedGuideId))) {
            throw RoomAdmissionV2Exception(RoomAdmissionV2Exception.Reason.WRONG_GUIDE)
        }
        val publicKey = plaintext.copyOfRange(26, 91)
        GuideFrameVerifier(publicKey, sessionId, expectedGuideId).verifyAdmissionProof(
            plaintext.copyOfRange(91, 155), transcript, plaintext.copyOf(91),
        )
        return AdmittedRoomCredentials(plaintext.copyOf(10).toString(Charsets.US_ASCII),
            AdmittedGuideIdentity(sessionId, expectedGuideId, publicKey))
    }

    private fun validMediaSecret(bytes: ByteArray): Boolean = bytes.size == SessionCredential.SHORT_CODE_LENGTH &&
        bytes.all { it.toInt() in 0..127 && it.toInt().toChar() in SessionCredential.ALPHABET }
}
