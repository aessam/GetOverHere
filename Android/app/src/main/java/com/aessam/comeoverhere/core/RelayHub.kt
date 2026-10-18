package com.aessam.comeoverhere.core

import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.RelayForwarder
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import java.util.UUID

/** One island peer's outbound side on one lane. In the app this wraps a `BoundedSocketFrameWriter`. */
interface RelayChildWriter {
    /** Queues one GOS1 guide frame; false when the peer is overloaded or gone (ADR-039 isolation). */
    fun enqueue(frame: ByteArray): Boolean
    fun close()
}

/**
 * The bridge's island fan-out (ADR-081 P1, CrossIslandDesign D3/D4). The bridge holds one upstream guest session
 * to the guide; every guide frame it receives there goes through [RelayForwarder], which verifies GOS1 against the
 * guide key pinned at admission before any state changes, and is then copied unchanged to each island peer on that
 * lane. Frames the bridge originates itself (relay welcome, served asset chunks, upstream records) never enter here.
 *
 * The hub also tracks the guide's newest `bridgeAssignment`: it must name this bridge, or the island is torn down.
 */
class RelayHub(
    private val bridgeID: UUID,
    private val verifier: GuideFrameVerifier,
    credential: SessionCredential,
    /** A guide frame failed verification or conflicted: drop that upstream route and fail over (D7). */
    private val onRouteFault: (SessionLane, String) -> Unit,
    /** The guide assigned another bridge (or a newer generation elsewhere): close the island (P3 failover seam). */
    private val onIslandRevoked: (BridgeAssignmentPayload) -> Unit,
) {
    data class Counters(val forwarded: Long, val duplicates: Long, val expired: Long, val conflicts: Long, val dropped: Long)

    private val forwarder = RelayForwarder(verifier)
    private val opener = SessionFrameOpener(credential)
    private val children = HashMap<SessionLane, MutableList<RelayChildWriter>>()
    private var forwarded = 0L
    private var duplicates = 0L
    private var expired = 0L
    private var conflicts = 0L
    private var dropped = 0L

    /** The guide-signed assignment frame naming this bridge; carried in every relay welcome (ADR-083 QST-8). */
    @get:Synchronized var assignmentFrame: ByteArray? = null
        private set
    @get:Synchronized var assignment: BridgeAssignmentPayload? = null
        private set

    @get:Synchronized val counters: Counters get() = Counters(forwarded, duplicates, expired, conflicts, dropped)

    /** Every GOS1 frame the bridge's upstream lanes deliver. */
    @Synchronized
    fun onUpstreamFrame(lane: SessionLane, frame: ByteArray, receivedAtMilliseconds: Long, nowMilliseconds: Long) {
        val decision = try {
            forwarder.admit(frame, receivedAtMilliseconds, nowMilliseconds)
        } catch (error: Exception) {
            onRouteFault(lane, "guide frame rejected: ${error.message ?: error.javaClass.simpleName}")
            return
        }
        when (decision) {
            RelayForwarder.Decision.DUPLICATE -> duplicates++
            RelayForwarder.Decision.EXPIRED -> expired++
            RelayForwarder.Decision.CONFLICT -> {
                conflicts++
                onRouteFault(lane, "guide frame identity reused with different bytes")
            }
            RelayForwarder.Decision.FORWARD -> {
                forwarded++
                if (lane == SessionLane.CONTROL) observeAssignment(frame)
                fanOut(lane, frame)
            }
        }
    }

    /** Registers an island peer after its relay lane handshake; control peers get the cached state first. */
    @Synchronized
    fun attach(lane: SessionLane, writer: RelayChildWriter) {
        if (lane == SessionLane.CONTROL) {
            for (frame in forwarder.snapshotFrames) {
                if (!writer.enqueue(frame)) { writer.close(); dropped++; return }
            }
        }
        children.getOrPut(lane) { mutableListOf() } += writer
    }

    @Synchronized
    fun detach(lane: SessionLane, writer: RelayChildWriter) {
        children[lane]?.remove(writer)
    }

    @Synchronized
    fun closeIsland() {
        children.values.flatten().forEach(RelayChildWriter::close)
        children.clear()
    }

    private fun fanOut(lane: SessionLane, frame: ByteArray) {
        val peers = children[lane] ?: return
        val iterator = peers.iterator()
        while (iterator.hasNext()) {
            val peer = iterator.next()
            if (!peer.enqueue(frame)) {
                peer.close()
                iterator.remove()
                dropped++
            }
        }
    }

    /** Opens only `bridgeAssignment` frames, which the bridge must read to know whether it is still the bridge. */
    private fun observeAssignment(frame: ByteArray) {
        val sealed = verifier.verify(frame) // already verified by the forwarder; this only recovers the envelope
        if (sealed.kind != SessionMessageKind.BRIDGE_ASSIGNMENT) return
        val opened = opener.open(sealed) as? SessionFrameOpenResult.Opened ?: return
        val value = BridgeAssignmentPayload.decode(opened.envelope.payload)
        val current = assignment
        if (current != null && java.lang.Long.compareUnsigned(value.generation, current.generation) < 0) return
        if (value.bridgeID == bridgeID) {
            assignment = value
            assignmentFrame = frame.copyOf()
        } else {
            assignment = null
            assignmentFrame = null
            closeIsland()
            onIslandRevoked(value)
        }
    }
}
