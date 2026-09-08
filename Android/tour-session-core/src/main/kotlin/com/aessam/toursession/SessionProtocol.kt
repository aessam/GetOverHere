package com.aessam.toursession

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.UUID

enum class SessionLane(val rawValue: Int) {
    REALTIME(1),
    CONTROL(2),
    ASSET(3);

    val wireName: String get() = name.lowercase()

    companion object {
        fun fromRaw(raw: Int): SessionLane = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("unknown lane $raw")
    }
}

enum class SessionMessageKind(val rawValue: Int, val requiredLane: SessionLane) {
    HELLO(0x01, SessionLane.CONTROL),
    WELCOME(0x02, SessionLane.CONTROL),
    HEARTBEAT(0x03, SessionLane.CONTROL),
    LEAVE(0x04, SessionLane.CONTROL),
    AUTH_CHALLENGE(0x05, SessionLane.CONTROL),
    AUDIO_FRAME(0x10, SessionLane.REALTIME),
    PRESENTATION_SNAPSHOT(0x20, SessionLane.CONTROL),
    BEARING_SNAPSHOT(0x21, SessionLane.CONTROL),
    TARGET_SNAPSHOT(0x22, SessionLane.CONTROL),
    VISUAL_FOCUS_SNAPSHOT(0x23, SessionLane.CONTROL),
    AUDIO_STATUS(0x24, SessionLane.CONTROL),
    ASSET_MANIFEST(0x30, SessionLane.ASSET),
    ASSET_CHUNK(0x31, SessionLane.ASSET),
    TOUR_PACK_MANIFEST(0x32, SessionLane.ASSET),
    ASSET_REQUEST(0x33, SessionLane.ASSET),
    ASSET_STATUS(0x34, SessionLane.ASSET);

    val wireName: String
        get() = when (this) {
            HELLO -> "hello"
            WELCOME -> "welcome"
            HEARTBEAT -> "heartbeat"
            LEAVE -> "leave"
            AUTH_CHALLENGE -> "authChallenge"
            AUDIO_FRAME -> "audioFrame"
            PRESENTATION_SNAPSHOT -> "presentationSnapshot"
            BEARING_SNAPSHOT -> "bearingSnapshot"
            TARGET_SNAPSHOT -> "targetSnapshot"
            VISUAL_FOCUS_SNAPSHOT -> "visualFocusSnapshot"
            AUDIO_STATUS -> "audioStatus"
            ASSET_MANIFEST -> "assetManifest"
            ASSET_CHUNK -> "assetChunk"
            TOUR_PACK_MANIFEST -> "tourPackManifest"
            ASSET_REQUEST -> "assetRequest"
            ASSET_STATUS -> "assetStatus"
        }

    companion object {
        fun fromRaw(raw: Int): SessionMessageKind = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("unknown message kind $raw")
    }
}

enum class SessionRole(val rawValue: Int) {
    GUIDE(1),
    GUEST(2);

    val wireName: String get() = name.lowercase()

    companion object {
        fun fromRaw(raw: Int): SessionRole = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("invalid role $raw")
    }
}

enum class ParticipantPlatform(val rawValue: Int) {
    IOS(1),
    ANDROID(2),
    HOST(3);

    val wireName: String get() = name.lowercase()

    companion object {
        fun fromRaw(raw: Int): ParticipantPlatform = entries.firstOrNull { it.rawValue == raw }
            ?: throw SessionProtocolException("invalid platform $raw")
    }
}

open class SessionProtocolException(message: String) : IllegalArgumentException(message)

class UnsupportedSessionVersionException(
    val receivedMajorVersion: Int,
    val supportedMajorVersion: Int,
) : SessionProtocolException("unsupported major version $receivedMajorVersion; this build requires $supportedMajorVersion")

data class SessionEnvelope(
    val majorVersion: Int = MAJOR_VERSION,
    val minorVersion: Int = MINOR_VERSION,
    val lane: SessionLane,
    val kind: SessionMessageKind,
    val flags: Int = 0,
    val sequence: Long,
    val sessionId: UUID,
    val senderId: UUID,
    val payload: ByteArray,
) {
    init {
        if (kind.requiredLane != lane) {
            throw SessionProtocolException("${kind.wireName} requires ${kind.requiredLane.wireName}, got ${lane.wireName}")
        }
        require(flags in 0..0xffff) { "flags must fit UInt16" }
    }

    override fun equals(other: Any?): Boolean =
        other is SessionEnvelope &&
            majorVersion == other.majorVersion &&
            minorVersion == other.minorVersion &&
            lane == other.lane &&
            kind == other.kind &&
            flags == other.flags &&
            sequence == other.sequence &&
            sessionId == other.sessionId &&
            senderId == other.senderId &&
            payload.contentEquals(other.payload)

    override fun hashCode(): Int = 31 * sessionId.hashCode() + payload.contentHashCode()

    fun encode(): ByteArray {
        val writer = BinaryWriter(HEADER_SIZE + payload.size)
        writer.append(MAGIC)
        writer.appendUInt8(majorVersion)
        writer.appendUInt8(minorVersion)
        writer.appendUInt8(lane.rawValue)
        writer.appendUInt8(kind.rawValue)
        writer.appendUInt16(flags)
        writer.appendUInt64(sequence)
        writer.appendUuid(sessionId)
        writer.appendUuid(senderId)
        writer.appendUInt32(payload.size.toLong())
        writer.append(payload)
        return writer.toByteArray()
    }

    companion object {
        const val MAJOR_VERSION = 2
        const val MINOR_VERSION = 1
        const val HEADER_SIZE = 54
        private val MAGIC = "GOH2".toByteArray(StandardCharsets.US_ASCII)

        fun decode(data: ByteArray): SessionEnvelope {
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
            val payloadLength = reader.readUInt32().toInt()
            if (reader.remaining != payloadLength) {
                throw SessionProtocolException(
                    "payload length mismatch: expected $payloadLength, got ${reader.remaining}",
                )
            }
            return SessionEnvelope(
                majorVersion = major,
                minorVersion = minor,
                lane = lane,
                kind = kind,
                flags = flags,
                sequence = sequence,
                sessionId = sessionId,
                senderId = senderId,
                payload = reader.readBytes(payloadLength),
            )
        }
    }
}

data class HelloPayload(
    val role: SessionRole,
    val platform: ParticipantPlatform,
    val capabilities: Long,
    val displayName: String,
    val requestedLane: SessionLane,
    val clientNonce: ByteArray,
    val credentialProof: ByteArray,
) {
    init {
        require(capabilities in 0..0xffff_ffffL) { "capabilities must fit UInt32" }
        require(clientNonce.size == SessionAuthenticator.NONCE_SIZE) { "invalid authentication nonce length" }
        require(credentialProof.size == SessionAuthenticator.PROOF_SIZE) { "invalid authentication proof length" }
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter()
        writer.appendUInt8(role.rawValue)
        writer.appendUInt8(platform.rawValue)
        writer.appendUInt32(capabilities)
        writer.appendString(displayName)
        writer.appendUInt8(requestedLane.rawValue)
        writer.append(clientNonce)
        writer.append(credentialProof)
        return writer.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray): HelloPayload {
            val reader = BinaryReader(data)
            val result = HelloPayload(
                role = SessionRole.fromRaw(reader.readUInt8()),
                platform = ParticipantPlatform.fromRaw(reader.readUInt8()),
                capabilities = reader.readUInt32(),
                displayName = reader.readString(),
                requestedLane = SessionLane.fromRaw(reader.readUInt8()),
                clientNonce = reader.readBytes(SessionAuthenticator.NONCE_SIZE),
                credentialProof = reader.readBytes(SessionAuthenticator.PROOF_SIZE),
            )
            if (reader.remaining != 0) {
                throw SessionProtocolException("hello payload has ${reader.remaining} trailing bytes")
            }
            return result
        }
    }
}

data class AuthChallengePayload(
    val requestedLane: SessionLane,
    val challengeNonce: ByteArray,
) {
    init {
        require(challengeNonce.size == SessionAuthenticator.NONCE_SIZE) { "invalid authentication nonce length" }
    }

    fun encode(): ByteArray = BinaryWriter().also {
        it.appendUInt8(requestedLane.rawValue)
        it.append(challengeNonce)
    }.toByteArray()

    companion object {
        fun decode(data: ByteArray): AuthChallengePayload {
            val reader = BinaryReader(data)
            val result = AuthChallengePayload(
                SessionLane.fromRaw(reader.readUInt8()),
                reader.readBytes(SessionAuthenticator.NONCE_SIZE),
            )
            if (reader.remaining != 0) throw SessionProtocolException("challenge payload has ${reader.remaining} trailing bytes")
            return result
        }
    }
}

data class WelcomePayload(
    val requestedLane: SessionLane,
    val guideNonce: ByteArray,
    val credentialProof: ByteArray,
) {
    init {
        require(guideNonce.size == SessionAuthenticator.NONCE_SIZE) { "invalid authentication nonce length" }
        require(credentialProof.size == SessionAuthenticator.PROOF_SIZE) { "invalid authentication proof length" }
    }

    fun encode(): ByteArray = BinaryWriter().also {
        it.appendUInt8(requestedLane.rawValue)
        it.append(guideNonce)
        it.append(credentialProof)
    }.toByteArray()

    companion object {
        fun decode(data: ByteArray): WelcomePayload {
            val reader = BinaryReader(data)
            val result = WelcomePayload(
                SessionLane.fromRaw(reader.readUInt8()),
                reader.readBytes(SessionAuthenticator.NONCE_SIZE),
                reader.readBytes(SessionAuthenticator.PROOF_SIZE),
            )
            if (reader.remaining != 0) throw SessionProtocolException("welcome payload has ${reader.remaining} trailing bytes")
            return result
        }
    }
}

internal class BinaryWriter(capacity: Int = 32) {
    private val output = ByteArrayOutputStream(capacity)

    fun appendUInt8(value: Int) {
        require(value in 0..0xff)
        output.write(value)
    }

    fun appendUInt16(value: Int) {
        require(value in 0..0xffff)
        output.write((value ushr 8) and 0xff)
        output.write(value and 0xff)
    }

    fun appendUInt32(value: Long) {
        require(value in 0..0xffff_ffffL)
        for (shift in 24 downTo 0 step 8) {
            output.write(((value ushr shift) and 0xff).toInt())
        }
    }

    fun appendInt32(value: Int) {
        appendUInt32(value.toLong() and 0xffff_ffffL)
    }

    fun appendUInt64(value: Long) {
        for (shift in 56 downTo 0 step 8) {
            output.write(((value ushr shift) and 0xff).toInt())
        }
    }

    fun appendUuid(value: UUID) {
        appendUInt64(value.mostSignificantBits)
        appendUInt64(value.leastSignificantBits)
    }

    fun appendString(value: String) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > 0xffff) {
            throw SessionProtocolException("UTF-8 string is ${bytes.size} bytes; maximum is 65535")
        }
        appendUInt16(bytes.size)
        append(bytes)
    }

    fun append(value: ByteArray) {
        output.write(value)
    }

    fun toByteArray(): ByteArray = output.toByteArray()
}

internal class BinaryReader(private val data: ByteArray) {
    private var offset = 0
    val remaining: Int get() = data.size - offset

    fun readUInt8(): Int {
        ensureAvailable(1)
        return data[offset++].toInt() and 0xff
    }

    fun readUInt16(): Int = (readUInt8() shl 8) or readUInt8()

    fun readUInt32(): Long {
        var value = 0L
        repeat(4) { value = (value shl 8) or readUInt8().toLong() }
        return value
    }

    fun readInt32(): Int = readUInt32().toInt()

    fun readUInt64(): Long {
        var value = 0L
        repeat(8) { value = (value shl 8) or readUInt8().toLong() }
        return value
    }

    fun readUuid(): UUID = UUID(readUInt64(), readUInt64())

    fun readString(): String {
        val count = readUInt16()
        val bytes = readBytes(count)
        return try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: CharacterCodingException) {
            throw SessionProtocolException("invalid UTF-8")
        }
    }

    fun readBytes(count: Int): ByteArray {
        ensureAvailable(count)
        val result = data.copyOfRange(offset, offset + count)
        offset += count
        return result
    }

    private fun ensureAvailable(count: Int) {
        if (count < 0 || remaining < count) {
            throw SessionProtocolException("truncated data")
        }
    }
}

fun ByteArray.lowercaseHex(): String = joinToString(separator = "") { "%02x".format(it) }

fun String.hexToByteArray(): ByteArray {
    if (length % 2 != 0) throw SessionProtocolException("hex length must be even")
    return chunked(2).map { pair ->
        pair.toIntOrNull(16)?.toByte() ?: throw SessionProtocolException("invalid hex")
    }.toByteArray()
}
