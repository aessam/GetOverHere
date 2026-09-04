package com.aessam.toursession

import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class SessionFrameSecurityException(message: String) : IllegalArgumentException(message)

data class SessionFrameIdentity(
    val sessionId: UUID,
    val senderId: UUID,
    val streamId: UUID,
    val lane: SessionLane,
    val kind: SessionMessageKind,
    val flags: Int,
    val sequence: Long,
) {
    override fun toString(): String =
        "session=${sessionId.toString().lowercase()},sender=${senderId.toString().lowercase()}," +
            "stream=${streamId.toString().lowercase()},lane=${lane.wireName}," +
            "kind=${kind.wireName},sequence=$sequence"
}

class SealedSessionEnvelope(
    val lane: SessionLane,
    val kind: SessionMessageKind,
    val flags: Int = 0,
    val sequence: Long,
    val sessionId: UUID,
    val senderId: UUID,
    val streamId: UUID,
    val sealedPayload: ByteArray,
    val minorVersion: Int = MINOR_VERSION,
) {
    init {
        if (kind.requiredLane != lane) {
            throw SessionProtocolException("${kind.wireName} requires ${kind.requiredLane.wireName}, got ${lane.wireName}")
        }
        require(flags in 0..0xffff) { "flags must fit UInt16" }
        require(minorVersion in 0..0xff) { "minorVersion must fit UInt8" }
        if (sealedPayload.size < SessionFrameCryptography.TAG_SIZE) {
            throw SessionFrameSecurityException(
                "sealed payload is ${sealedPayload.size} bytes; minimum is ${SessionFrameCryptography.TAG_SIZE}",
            )
        }
    }

    val identity: SessionFrameIdentity
        get() = SessionFrameIdentity(sessionId, senderId, streamId, lane, kind, flags, sequence)

    override fun equals(other: Any?): Boolean =
        other is SealedSessionEnvelope &&
            minorVersion == other.minorVersion &&
            lane == other.lane &&
            kind == other.kind &&
            flags == other.flags &&
            sequence == other.sequence &&
            sessionId == other.sessionId &&
            senderId == other.senderId &&
            streamId == other.streamId &&
            sealedPayload.contentEquals(other.sealedPayload)

    override fun hashCode(): Int = 31 * identity.hashCode() + sealedPayload.contentHashCode()

    fun encode(): ByteArray = headerBytes(
        lane,
        kind,
        flags,
        sequence,
        sessionId,
        senderId,
        streamId,
        sealedPayload.size,
        minorVersion,
    ) + sealedPayload

    companion object {
        const val MAJOR_VERSION = 4
        const val MINOR_VERSION = 0
        const val HEADER_SIZE = 70
        private val MAGIC = "GOH2".toByteArray(StandardCharsets.US_ASCII)

        fun decode(data: ByteArray): SealedSessionEnvelope {
            val reader = BinaryReader(data)
            if (!reader.readBytes(MAGIC.size).contentEquals(MAGIC)) {
                throw SessionProtocolException("invalid GOH2 magic")
            }
            val major = reader.readUInt8()
            if (major != MAJOR_VERSION) {
                throw UnsupportedSessionVersionException(major, MAJOR_VERSION)
            }
            val minor = reader.readUInt8()
            val lane = SessionLane.fromRaw(reader.readUInt8())
            val kind = SessionMessageKind.fromRaw(reader.readUInt8())
            val flags = reader.readUInt16()
            val sequence = reader.readUInt64()
            val sessionId = reader.readUuid()
            val senderId = reader.readUuid()
            val streamId = reader.readUuid()
            val payloadLength = reader.readUInt32().toInt()
            if (reader.remaining != payloadLength) {
                throw SessionProtocolException(
                    "payload length mismatch: expected $payloadLength, got ${reader.remaining}",
                )
            }
            return SealedSessionEnvelope(
                lane = lane,
                kind = kind,
                flags = flags,
                sequence = sequence,
                sessionId = sessionId,
                senderId = senderId,
                streamId = streamId,
                sealedPayload = reader.readBytes(payloadLength),
                minorVersion = minor,
            )
        }

        internal fun headerBytes(
            lane: SessionLane,
            kind: SessionMessageKind,
            flags: Int,
            sequence: Long,
            sessionId: UUID,
            senderId: UUID,
            streamId: UUID,
            sealedPayloadLength: Int,
            minorVersion: Int = MINOR_VERSION,
        ): ByteArray {
            require(sealedPayloadLength >= 0)
            require(minorVersion in 0..0xff)
            val writer = BinaryWriter(HEADER_SIZE)
            writer.append(MAGIC)
            writer.appendUInt8(MAJOR_VERSION)
            writer.appendUInt8(minorVersion)
            writer.appendUInt8(lane.rawValue)
            writer.appendUInt8(kind.rawValue)
            writer.appendUInt16(flags)
            writer.appendUInt64(sequence)
            writer.appendUuid(sessionId)
            writer.appendUuid(senderId)
            writer.appendUuid(streamId)
            writer.appendUInt32(sealedPayloadLength.toLong())
            return writer.toByteArray()
        }
    }
}

sealed interface SessionFrameOpenResult {
    data class Opened(val envelope: SessionEnvelope) : SessionFrameOpenResult
    data class Duplicate(val identity: SessionFrameIdentity) : SessionFrameOpenResult
}

class SessionFrameSealer(
    credential: SessionCredential,
    private val cacheLimit: Int = 256,
    private val protocolMinorVersion: Int = SealedSessionEnvelope.MINOR_VERSION,
) {
    private data class StreamScope(val sessionId: UUID, val senderId: UUID, val streamId: UUID)
    private data class CachedFrame(val payloadDigest: ByteArray, val envelope: SealedSessionEnvelope)

    private val applicationKey = SessionFrameCryptography.applicationKey(credential)
    private val highestSequence = mutableMapOf<StreamScope, Long>()
    private val cache = LinkedHashMap<SessionFrameIdentity, CachedFrame>()

    init {
        require(cacheLimit > 0)
        require(protocolMinorVersion in 0..0xff)
    }

    @Synchronized
    fun seal(envelope: SessionEnvelope, streamId: UUID): SealedSessionEnvelope {
        val identity = SessionFrameIdentity(
            envelope.sessionId,
            envelope.senderId,
            streamId,
            envelope.lane,
            envelope.kind,
            envelope.flags,
            envelope.sequence,
        )
        val payloadDigest = MessageDigest.getInstance("SHA-256").digest(envelope.payload)
        cache[identity]?.let { cached ->
            if (!cached.payloadDigest.contentEquals(payloadDigest)) {
                throw SessionFrameSecurityException("session frame identity was reused: $identity")
            }
            return cached.envelope
        }

        val scope = StreamScope(envelope.sessionId, envelope.senderId, streamId)
        val highest = highestSequence[scope]
        if (highest != null && envelope.sequence <= highest) {
            throw SessionFrameSecurityException("session frame identity was reused: $identity")
        }

        val sealedLength = envelope.payload.size + SessionFrameCryptography.TAG_SIZE
        val header = SealedSessionEnvelope.headerBytes(
            envelope.lane,
            envelope.kind,
            envelope.flags,
            envelope.sequence,
            envelope.sessionId,
            envelope.senderId,
            streamId,
            sealedLength,
            protocolMinorVersion,
        )
        val sealedPayload = SessionFrameCryptography.seal(
            envelope.payload,
            identity,
            header,
            applicationKey,
        )
        val sealed = SealedSessionEnvelope(
            lane = envelope.lane,
            kind = envelope.kind,
            flags = envelope.flags,
            sequence = envelope.sequence,
            sessionId = envelope.sessionId,
            senderId = envelope.senderId,
            streamId = streamId,
            sealedPayload = sealedPayload,
            minorVersion = protocolMinorVersion,
        )
        highestSequence[scope] = envelope.sequence
        cache[identity] = CachedFrame(payloadDigest, sealed)
        if (cache.size > cacheLimit) cache.remove(cache.keys.first())
        return sealed
    }
}

class SessionFrameOpener(
    credential: SessionCredential,
    private val replayWindow: Int = 4_096,
) {
    private data class StreamScope(val sessionId: UUID, val senderId: UUID, val streamId: UUID)
    private data class AcceptedFrame(val identity: SessionFrameIdentity, val sealedDigest: ByteArray)
    private data class StreamWindow(
        var highestSequence: Long,
        val accepted: MutableMap<Long, AcceptedFrame> = mutableMapOf(),
    )

    private val applicationKey = SessionFrameCryptography.applicationKey(credential)
    private val streamWindows = mutableMapOf<StreamScope, StreamWindow>()

    init {
        require(replayWindow > 0)
    }

    @Synchronized
    fun open(sealed: SealedSessionEnvelope): SessionFrameOpenResult {
        val scope = StreamScope(sealed.sessionId, sealed.senderId, sealed.streamId)
        val sealedDigest = MessageDigest.getInstance("SHA-256").digest(sealed.sealedPayload)
        streamWindows[scope]?.let { window ->
            val floor = replayFloor(window.highestSequence)
            if (sealed.sequence < floor) {
                throw SessionFrameSecurityException("session frame fell outside replay window: ${sealed.identity}")
            }
            window.accepted[sealed.sequence]?.let { accepted ->
                if (accepted.identity != sealed.identity || !accepted.sealedDigest.contentEquals(sealedDigest)) {
                    throw SessionFrameSecurityException("session frame identity was reused: ${sealed.identity}")
                }
                return SessionFrameOpenResult.Duplicate(sealed.identity)
            }
        }

        val header = SealedSessionEnvelope.headerBytes(
            sealed.lane,
            sealed.kind,
            sealed.flags,
            sealed.sequence,
            sealed.sessionId,
            sealed.senderId,
            sealed.streamId,
            sealed.sealedPayload.size,
            sealed.minorVersion,
        )
        val payload = SessionFrameCryptography.open(
            sealed.sealedPayload,
            sealed.identity,
            header,
            applicationKey,
        )
        val envelope = SessionEnvelope(
            majorVersion = SealedSessionEnvelope.MAJOR_VERSION,
            minorVersion = sealed.minorVersion,
            lane = sealed.lane,
            kind = sealed.kind,
            flags = sealed.flags,
            sequence = sealed.sequence,
            sessionId = sealed.sessionId,
            senderId = sealed.senderId,
            payload = payload,
        )

        val window = streamWindows.getOrPut(scope) { StreamWindow(sealed.sequence) }
        if (sealed.sequence > window.highestSequence) {
            val oldFloor = replayFloor(window.highestSequence)
            val newFloor = replayFloor(sealed.sequence)
            if (newFloor > oldFloor) {
                if (newFloor - oldFloor >= replayWindow.toLong()) {
                    window.accepted.clear()
                } else {
                    for (sequence in oldFloor until newFloor) {
                        window.accepted.remove(sequence)
                    }
                }
            }
            window.highestSequence = sealed.sequence
        }
        window.accepted[sealed.sequence] = AcceptedFrame(sealed.identity, sealedDigest)
        return SessionFrameOpenResult.Opened(envelope)
    }

    private fun replayFloor(highestSequence: Long): Long =
        maxOf(0, highestSequence - (replayWindow - 1).toLong())
}

private object SessionFrameCryptography {
    const val TAG_SIZE = 16
    private const val NONCE_SIZE = 12

    fun applicationKey(credential: SessionCredential): ByteArray = SessionAuthenticator.hmac(
        credential.key,
        "GetOverHere/GOH3/application-payload-key/v1".toByteArray(StandardCharsets.US_ASCII),
    )

    fun seal(
        plaintext: ByteArray,
        identity: SessionFrameIdentity,
        authenticatedHeader: ByteArray,
        applicationKey: ByteArray,
    ): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(applicationKey, "AES"),
            GCMParameterSpec(TAG_SIZE * 8, nonce(identity, applicationKey)),
        )
        cipher.updateAAD(authenticatedHeader)
        return cipher.doFinal(plaintext)
    }

    fun open(
        sealedPayload: ByteArray,
        identity: SessionFrameIdentity,
        authenticatedHeader: ByteArray,
        applicationKey: ByteArray,
    ): ByteArray {
        if (sealedPayload.size < TAG_SIZE) {
            throw SessionFrameSecurityException(
                "sealed payload is ${sealedPayload.size} bytes; minimum is $TAG_SIZE",
            )
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(applicationKey, "AES"),
            GCMParameterSpec(TAG_SIZE * 8, nonce(identity, applicationKey)),
        )
        cipher.updateAAD(authenticatedHeader)
        return try {
            cipher.doFinal(sealedPayload)
        } catch (_: AEADBadTagException) {
            throw SessionFrameSecurityException("session frame authentication failed")
        }
    }

    private fun nonce(identity: SessionFrameIdentity, applicationKey: ByteArray): ByteArray {
        val writer = BinaryWriter()
        writer.append("GetOverHere/GOH3/frame-nonce/v1".toByteArray(StandardCharsets.US_ASCII))
        writer.appendUuid(identity.sessionId)
        writer.appendUuid(identity.senderId)
        writer.appendUuid(identity.streamId)
        writer.appendUInt8(identity.lane.rawValue)
        writer.appendUInt8(identity.kind.rawValue)
        writer.appendUInt16(identity.flags)
        writer.appendUInt64(identity.sequence)
        return SessionAuthenticator.hmac(applicationKey, writer.toByteArray()).copyOf(NONCE_SIZE)
    }
}
