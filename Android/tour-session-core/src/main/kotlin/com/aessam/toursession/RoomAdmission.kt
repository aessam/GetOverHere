package com.aessam.toursession

import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class RoomAdmissionException(message: String) : IllegalArgumentException(message)

class RoomAccessPolicy(sessionID: UUID, code: String?) {
    val isLocked = code != null
    internal val secret: ByteArray = if (code == null) ByteArray(32) else {
        require(isValidCode(code)) { "Room code must contain 4–64 printable characters (no spaces)." }
        SessionCredential.stretch(code, RoomAdmission.identity(sessionID) + "GetOverHere/room-code/v1".toByteArray())
    }

    companion object {
        fun isValidCode(code: String): Boolean = code.length in 4..64 && code.all { it.code in 33..126 }
    }
}

/** Fixed-size bootstrap shared with Swift; media credentials never change with room settings. */
object RoomAdmission {
    const val PORT = 50003
    const val CHALLENGE_SIZE = 103
    const val REQUEST_SIZE = 97
    const val REPLY_SIZE = 38
    private val magic = byteArrayOf(0x47, 0x4f, 0x48, 0x52, 1)
    internal fun identity(id: UUID): ByteArray = ByteBuffer.allocate(16)
        .putLong(id.mostSignificantBits).putLong(id.leastSignificantBits).array()

    class Guide(sessionID: UUID, private val policy: RoomAccessPolicy) {
        private val key = newKey()
        val challenge: ByteArray = magic + identity(sessionID) + byteArrayOf(if (policy.isLocked) 1 else 0) +
            SessionAuthenticator.randomNonce() + publicBytes(key)

        fun reply(request: ByteArray, sessionCode: String): ByteArray {
            require(request.size == REQUEST_SIZE && sessionCode.length == SessionCredential.SHORT_CODE_LENGTH &&
                sessionCode.all { it in SessionCredential.ALPHABET })
            val publicKey = request.copyOfRange(0, 65)
            val transcript = challenge + publicKey
            val sharedKey = derive(key, publicKey, policy.secret, transcript)
            require(SessionAuthenticator.securelyMatches(
                SessionAuthenticator.hmac(sharedKey, transcript), request.copyOfRange(65, 97),
            )) { "Room admission failed. Check the code and try again." }
            val nonce = SessionAuthenticator.randomNonce().copyOf(12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sharedKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(transcript)
            return nonce + cipher.doFinal(sessionCode.toByteArray(Charsets.US_ASCII))
        }
    }

    class Guest(challenge: ByteArray, sessionID: UUID, code: String?) {
        val request: ByteArray
        private val key: ByteArray
        private val transcript: ByteArray

        init {
            require(challenge.size == CHALLENGE_SIZE &&
                challenge.copyOfRange(0, 21).contentEquals(magic + identity(sessionID)) &&
                challenge[21].toInt() in 0..1) { "Invalid room admission message." }
            val locked = challenge[21].toInt() == 1
            if (locked && code == null) throw RoomAdmissionException("This room is locked. Ask the guide for the room code.")
            if (!locked && code != null) throw RoomAdmissionException("Room access changed. Select the room again.")
            val policy = RoomAccessPolicy(sessionID, code)
            val ephemeral = newKey()
            val publicKey = publicBytes(ephemeral)
            transcript = challenge + publicKey
            key = derive(ephemeral, challenge.copyOfRange(38, 103), policy.secret, transcript)
            request = publicKey + SessionAuthenticator.hmac(key, transcript)
        }

        fun open(reply: ByteArray): String {
            require(reply.size == REPLY_SIZE) { "Invalid room admission reply." }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, reply.copyOf(12)))
            cipher.updateAAD(transcript)
            val code = cipher.doFinal(reply.copyOfRange(12, reply.size)).toString(Charsets.US_ASCII)
            require(code.length == SessionCredential.SHORT_CODE_LENGTH && code.all { it in SessionCredential.ALPHABET })
            return code
        }
    }

    internal fun newKey(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    internal fun publicBytes(key: KeyPair): ByteArray {
        val publicKey = key.public as ECPublicKey
        fun coordinate(value: BigInteger): ByteArray = value.toByteArray().let {
            if (it.size >= 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it
        }
        return byteArrayOf(4) + coordinate(publicKey.w.affineX) + coordinate(publicKey.w.affineY)
    }

    internal fun derive(key: KeyPair, peer: ByteArray, salt: ByteArray, transcript: ByteArray,
        domain: String = "GetOverHere/room-admission/v1"): ByteArray {
        require(peer.size == 65 && peer[0].toInt() == 4)
        val parameters = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(BigInteger(1, peer.copyOfRange(1, 33)), BigInteger(1, peer.copyOfRange(33, 65)))
        val publicKey = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
        val shared = KeyAgreement.getInstance("ECDH").apply { init(key.private); doPhase(publicKey, true) }.generateSecret()
        require(shared.size == 32) { "ECDH provider must return a fixed-width P-256 secret" }
        val extracted = SessionAuthenticator.hmac(salt, shared)
        return SessionAuthenticator.hmac(extracted, domain.toByteArray(Charsets.US_ASCII) + transcript + byteArrayOf(1))
    }
}
