package com.aessam.toursession

import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class SessionSecurityException(message: String) : IllegalArgumentException(message)

class SessionCredential private constructor(internal val key: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is SessionCredential && key.contentEquals(other.key)

    override fun hashCode(): Int = key.contentHashCode()

    companion object {
        const val SHORT_CODE_LENGTH = 10
        const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

        fun derive(shortCode: String, sessionID: UUID): SessionCredential {
            val normalized = normalize(shortCode)
            if (normalized.length != SHORT_CODE_LENGTH || normalized.any { it !in ALPHABET }) {
                throw SessionSecurityException("tour code must contain 10 unambiguous letters or digits")
            }
            val inputKey = normalized.toByteArray(StandardCharsets.US_ASCII)
            val pseudoRandomKey = SessionAuthenticator.hmac(sessionID.wireBytes(), inputKey)
            val info = "GetOverHere/GOH2/session-key/v1".toByteArray(StandardCharsets.US_ASCII) + byteArrayOf(1)
            return SessionCredential(SessionAuthenticator.hmac(pseudoRandomKey, info))
        }

        fun generateShortCode(random: SecureRandom = SecureRandom()): String = buildString {
            repeat(SHORT_CODE_LENGTH) { append(ALPHABET[random.nextInt(ALPHABET.length)]) }
        }

        fun normalize(code: String): String = code.uppercase().filterNot { it.isWhitespace() || it == '-' }
    }
}

object SessionAuthenticator {
    const val NONCE_SIZE = 16
    const val PROOF_SIZE = 32
    private val secureRandom = SecureRandom()

    fun randomNonce(): ByteArray = ByteArray(NONCE_SIZE).also(secureRandom::nextBytes)

    fun guestProof(
        credential: SessionCredential,
        sessionID: UUID,
        guideID: UUID,
        participantID: UUID,
        requestedLane: SessionLane,
        challengeNonce: ByteArray,
        clientNonce: ByteArray,
        role: SessionRole,
        platform: ParticipantPlatform,
        capabilities: Long,
        displayName: String,
    ): ByteArray {
        validateNonce(challengeNonce)
        validateNonce(clientNonce)
        val writer = BinaryWriter()
        writer.append("GetOverHere/GOH2/guest-auth/v1".toByteArray(StandardCharsets.US_ASCII))
        writer.appendUuid(sessionID)
        writer.appendUuid(guideID)
        writer.appendUuid(participantID)
        writer.appendUInt8(requestedLane.rawValue)
        writer.append(challengeNonce)
        writer.append(clientNonce)
        writer.appendUInt8(role.rawValue)
        writer.appendUInt8(platform.rawValue)
        writer.appendUInt32(capabilities)
        writer.appendString(displayName)
        return hmac(credential.key, writer.toByteArray())
    }

    fun guideProof(
        credential: SessionCredential,
        sessionID: UUID,
        guideID: UUID,
        participantID: UUID,
        requestedLane: SessionLane,
        challengeNonce: ByteArray,
        clientNonce: ByteArray,
        guideNonce: ByteArray,
    ): ByteArray {
        validateNonce(challengeNonce)
        validateNonce(clientNonce)
        validateNonce(guideNonce)
        val writer = BinaryWriter()
        writer.append("GetOverHere/GOH2/guide-auth/v1".toByteArray(StandardCharsets.US_ASCII))
        writer.appendUuid(sessionID)
        writer.appendUuid(guideID)
        writer.appendUuid(participantID)
        writer.appendUInt8(requestedLane.rawValue)
        writer.append(challengeNonce)
        writer.append(clientNonce)
        writer.append(guideNonce)
        return hmac(credential.key, writer.toByteArray())
    }

    fun securelyMatches(lhs: ByteArray, rhs: ByteArray): Boolean {
        if (lhs.size != rhs.size) return false
        var difference = 0
        lhs.indices.forEach { difference = difference or (lhs[it].toInt() xor rhs[it].toInt()) }
        return difference == 0
    }

    internal fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun validateNonce(nonce: ByteArray) {
        if (nonce.size != NONCE_SIZE) {
            throw SessionSecurityException("authentication nonce is ${nonce.size} bytes; expected $NONCE_SIZE")
        }
    }
}

private fun UUID.wireBytes(): ByteArray = BinaryWriter(16).also { it.appendUuid(this) }.toByteArray()
