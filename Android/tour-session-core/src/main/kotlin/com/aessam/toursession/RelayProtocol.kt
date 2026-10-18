package com.aessam.toursession

import java.security.MessageDigest
import java.util.UUID

/** Cross-island relay (ADR-081, CrossIslandDesign.md). Pure and byte-identical to the Swift RelayProtocol. */
class RelayProtocolException(message: String) : SessionProtocolException(message)

/**
 * W1: the guide's signed choice of the single cross-platform bridge (control lane, kind 0x25).
 * Only the guide sends it; a far guest whose host does not match the newest generation disconnects.
 */
data class BridgeAssignmentPayload(
    val generation: Long,
    val bridgeID: UUID,
    val bridgePlatform: ParticipantPlatform,
    val leaseExpiresAtMilliseconds: Long,
    val standbyIDs: List<UUID>,
) {
    init {
        if (standbyIDs.size > MAXIMUM_STANDBYS) throw RelayProtocolException("tooManyStandbys ${standbyIDs.size}")
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter(42 + 16 * standbyIDs.size)
        writer.appendUInt64(generation)
        writer.appendUuid(bridgeID)
        writer.appendUInt8(bridgePlatform.rawValue)
        writer.appendUInt64(leaseExpiresAtMilliseconds)
        writer.appendUInt8(standbyIDs.size)
        standbyIDs.forEach(writer::appendUuid)
        return writer.toByteArray()
    }

    companion object {
        const val MAXIMUM_STANDBYS = 2

        fun decode(data: ByteArray): BridgeAssignmentPayload {
            val reader = BinaryReader(data)
            val generation = reader.readUInt64()
            val bridgeID = reader.readUuid()
            val rawPlatform = reader.readUInt8()
            val platform = ParticipantPlatform.entries.firstOrNull { it.rawValue == rawPlatform && it != ParticipantPlatform.HOST }
                ?: throw RelayProtocolException("invalidPlatform $rawPlatform")
            val expires = reader.readUInt64()
            val count = reader.readUInt8()
            if (count > MAXIMUM_STANDBYS) throw RelayProtocolException("tooManyStandbys $count")
            val standbys = List(count) { reader.readUuid() }
            if (reader.remaining != 0) throw RelayProtocolException("trailingBytes ${reader.remaining}")
            return BridgeAssignmentPayload(generation, bridgeID, platform, expires, standbys)
        }
    }
}

/**
 * W5: a far guest's frame carried up the bridge's single control channel to the guide.
 * `version 1 | farParticipantID 16 | lane 1 | length u32 | frame`. The guide treats the contents as advisory.
 */
class RelayUpstreamRecord(val farParticipantID: UUID, val lane: SessionLane, val frame: ByteArray) {
    init {
        if (frame.size > MAXIMUM_FRAME_LENGTH) throw RelayProtocolException("frameTooLarge ${frame.size}")
    }

    fun encode(): ByteArray {
        val writer = BinaryWriter(HEADER_LENGTH + frame.size)
        writer.appendUInt8(VERSION)
        writer.appendUuid(farParticipantID)
        writer.appendUInt8(lane.rawValue)
        writer.appendUInt32(frame.size.toLong())
        writer.append(frame)
        return writer.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is RelayUpstreamRecord &&
        farParticipantID == other.farParticipantID && lane == other.lane && frame.contentEquals(other.frame)
    override fun hashCode(): Int = (farParticipantID.hashCode() * 31 + lane.hashCode()) * 31 + frame.contentHashCode()

    companion object {
        const val VERSION = 1
        const val HEADER_LENGTH = 22
        const val MAXIMUM_FRAME_LENGTH = 64 * 1024

        fun decode(data: ByteArray): RelayUpstreamRecord {
            val reader = BinaryReader(data)
            val version = reader.readUInt8()
            if (version != VERSION) throw RelayProtocolException("invalidVersion $version")
            val participant = reader.readUuid()
            val rawLane = reader.readUInt8()
            val lane = SessionLane.entries.firstOrNull { it.rawValue == rawLane } ?: throw RelayProtocolException("invalidLane $rawLane")
            val length = reader.readUInt32()
            if (length > MAXIMUM_FRAME_LENGTH) throw RelayProtocolException("frameTooLarge $length")
            val frame = reader.readBytes(length.toInt())
            if (reader.remaining != 0) throw RelayProtocolException("trailingBytes ${reader.remaining}")
            return RelayUpstreamRecord(participant, lane, frame)
        }
    }
}

/**
 * The bridge's per-session forwarding state: duplicate suppression across routes, a residence bound for
 * speech, and the latest control snapshot per kind for far guests that join later.
 *
 * Every frame is verified against the guide key pinned at admission before any state changes, so no admitted
 * member can claim a frame identity first or poison the snapshot cache. A verification failure throws; the
 * bridge treats it as a route fault and fails over (CrossIslandDesign D7).
 */
class RelayForwarder(private val verifier: GuideFrameVerifier) {
    enum class Decision { FORWARD, DUPLICATE, CONFLICT, EXPIRED }

    data class Identity(val sessionID: UUID, val senderID: UUID, val streamID: UUID, val sequence: Long)

    private val seen = HashMap<Identity, ByteArray>()
    private val order = ArrayDeque<Identity>()
    private val snapshots = HashMap<SessionMessageKind, Pair<Long, ByteArray>>()

    /**
     * Decides what to do with one GOS1 guide frame, given when it arrived and when it is about to be forwarded.
     * Throws when the signature, session or guide does not match the pinned guide.
     */
    fun admit(frame: ByteArray, receivedAtMilliseconds: Long, nowMilliseconds: Long): Decision {
        val envelope = verifier.verify(frame)
        val identity = Identity(envelope.sessionId, envelope.senderId, envelope.streamId, envelope.sequence)
        val digest = MessageDigest.getInstance("SHA-256").digest(frame)
        seen[identity]?.let { return if (it.contentEquals(digest)) Decision.DUPLICATE else Decision.CONFLICT }
        if (envelope.lane == SessionLane.REALTIME && nowMilliseconds >= receivedAtMilliseconds &&
            nowMilliseconds - receivedAtMilliseconds > AUDIO_RESIDENCE_MILLISECONDS
        ) return Decision.EXPIRED
        seen[identity] = digest
        order.addLast(identity)
        if (order.size > WINDOW_SIZE) seen.remove(order.removeFirst())
        if (envelope.lane == SessionLane.CONTROL && envelope.kind in SNAPSHOT_KINDS &&
            java.lang.Long.compareUnsigned(snapshots[envelope.kind]?.first ?: 0L, envelope.sequence) <= 0
        ) snapshots[envelope.kind] = envelope.sequence to frame
        return Decision.FORWARD
    }

    /** Control state a far guest needs on join, replayed locally in sequence order (no bridge bytes). */
    val snapshotFrames: List<ByteArray>
        get() = snapshots.values.sortedWith { a, b -> java.lang.Long.compareUnsigned(a.first, b.first) }.map { it.second }

    /** `kind:sequence` of the cached snapshots in replay order (fixtures and diagnostics). */
    val snapshotSummary: List<String>
        get() = snapshots.entries.sortedWith { a, b -> java.lang.Long.compareUnsigned(a.value.first, b.value.first) }
            .map { "${it.key.wireName}:${java.lang.Long.toUnsignedString(it.value.first)}" }

    companion object {
        const val WINDOW_SIZE = 4_096
        const val AUDIO_RESIDENCE_MILLISECONDS = 50L
        private val SNAPSHOT_KINDS = setOf(
            SessionMessageKind.PRESENTATION_SNAPSHOT, SessionMessageKind.BEARING_SNAPSHOT, SessionMessageKind.TARGET_SNAPSHOT,
            SessionMessageKind.VISUAL_FOCUS_SNAPSHOT, SessionMessageKind.BRIDGE_ASSIGNMENT,
        )
    }
}
