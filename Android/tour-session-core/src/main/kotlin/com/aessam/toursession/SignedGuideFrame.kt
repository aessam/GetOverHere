package com.aessam.toursession

import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.UUID

/** Sign once and forward unchanged. No verification key is accepted from the packet. */
class SignedGuideFrame internal constructor(bytes: ByteArray) {
    private val bytes = bytes.copyOf()
    fun encode(): ByteArray = bytes.copyOf()
    companion object {
        const val MAXIMUM_SEALED_SIZE = 65_536
        internal val MAGIC = "GOS1".toByteArray(Charsets.US_ASCII)
        internal val DOMAIN = "GetOverHere/signed-guide/v1\u0000".toByteArray(Charsets.US_ASCII)
    }
}

class GuideFrameSigner(private val sessionId: UUID, private val guideId: UUID) {
    private val key = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()
    val publicKey: ByteArray get() {
        val point = (key.public as ECPublicKey).w
        fun coordinate(value: BigInteger): ByteArray {
            val bytes = value.toByteArray()
            return if (bytes.size >= 32) bytes.takeLast(32).toByteArray() else ByteArray(32 - bytes.size) + bytes
        }
        return byteArrayOf(4) + coordinate(point.affineX) + coordinate(point.affineY)
    }
    fun sign(frame: SealedSessionEnvelope): SignedGuideFrame {
        require(frame.sessionId == sessionId && frame.senderId == guideId) { "Wrong guide/session" }
        val sealed = frame.encode()
        require(sealed.size <= SignedGuideFrame.MAXIMUM_SEALED_SIZE) { "Guide frame too large" }
        val body = SignedGuideFrame.MAGIC + ByteBuffer.allocate(4).putInt(sealed.size).array() + sealed
        val der = Signature.getInstance("SHA256withECDSA").run {
            initSign(key.private); update(SignedGuideFrame.DOMAIN + body); sign()
        }
        return SignedGuideFrame(body + GuideSignatureEncoding.canonical(GuideSignatureEncoding.raw(der)))
    }
}

class GuideFrameVerifier(pinnedPublicKey: ByteArray, private val sessionId: UUID, private val guideId: UUID) {
    private val key = run {
        require(pinnedPublicKey.size == 65 && pinnedPublicKey[0] == 4.toByte()) { "Invalid pinned key" }
        val parameters = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(BigInteger(1, pinnedPublicKey.copyOfRange(1, 33)), BigInteger(1, pinnedPublicKey.copyOfRange(33, 65)))
        KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
    }
    fun verify(packet: ByteArray): SealedSessionEnvelope {
        require(packet.size in 158..(SignedGuideFrame.MAXIMUM_SEALED_SIZE + 72)) { "Invalid guide frame size" }
        val bytes = packet.copyOf()
        require(bytes.copyOfRange(0, 4).contentEquals(SignedGuideFrame.MAGIC)) { "Unsigned guide frame" }
        require(ByteBuffer.wrap(bytes, 4, 4).int == bytes.size - 72) { "Invalid guide frame length" }
        val body = bytes.copyOfRange(0, bytes.size - 64)
        val raw = bytes.takeLast(64).toByteArray()
        require(GuideSignatureEncoding.canonical(raw).contentEquals(raw)) { "Noncanonical guide signature" }
        val signature = GuideSignatureEncoding.der(raw)
        require(Signature.getInstance("SHA256withECDSA").run {
            initVerify(key); update(SignedGuideFrame.DOMAIN + body); verify(signature)
        }) { "Invalid guide signature" }
        val sealed = SealedSessionEnvelope.decode(body.copyOfRange(8, body.size))
        require(sealed.sessionId == sessionId && sealed.senderId == guideId) { "Wrong guide/session" }
        return sealed
    }
}

/** Android's SHA256withECDSA uses DER; the wire uses fixed-width unsigned r || s. */
internal object GuideSignatureEncoding {
    val order = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
    fun canonical(raw: ByteArray): ByteArray {
        require(raw.size == 64)
        val r = BigInteger(1, raw.copyOfRange(0, 32))
        val s = BigInteger(1, raw.copyOfRange(32, 64))
        require(r.signum() > 0 && r < order && s.signum() > 0 && s < order)
        val low = minOf(s, order - s).toByteArray()
        val padded = if (low.size >= 32) low.takeLast(32).toByteArray() else ByteArray(32 - low.size) + low
        return raw.copyOfRange(0, 32) + padded
    }
    fun raw(der: ByteArray): ByteArray {
        require(der.size in 8..72 && der[0] == 0x30.toByte() && der[1].toInt() == der.size - 2)
        var offset = 2
        fun integer(): ByteArray {
            require(offset + 2 <= der.size && der[offset++] == 2.toByte())
            val count = der[offset++].toInt() and 255
            require(count in 1..33 && offset + count <= der.size)
            val part = der.copyOfRange(offset, offset + count); offset += count
            require(part[0].toInt() >= 0)
            require(count == 1 || part[0] != 0.toByte() || part[1].toInt() < 0)
            val positive = if (count > 1 && part[0] == 0.toByte()) part.drop(1).toByteArray() else part
            require(positive.size <= 32)
            return ByteArray(32 - positive.size) + positive
        }
        val result = integer() + integer()
        require(offset == der.size)
        return result
    }
    fun der(raw: ByteArray): ByteArray {
        require(raw.size == 64)
        fun integer(part: ByteArray): ByteArray {
            val digits = part.dropWhile { it == 0.toByte() }.toByteArray()
            val stripped = if (digits.isEmpty()) byteArrayOf(0) else digits
            val positive = if (stripped[0].toInt() < 0) byteArrayOf(0) + stripped else stripped
            return byteArrayOf(2, positive.size.toByte()) + positive
        }
        val body = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        return byteArrayOf(0x30, body.size.toByte()) + body
    }
}
