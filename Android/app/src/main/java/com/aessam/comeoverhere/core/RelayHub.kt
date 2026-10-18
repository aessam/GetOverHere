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
    /** Newest guide-signed tour manifest; replayed to island asset peers so they know which hashes to request. */
    private var manifestFrame: ByteArray? = null
    @get:Synchronized var assignmentFrame: ByteArray? = null
        private set
    @get:Synchronized var assignment: BridgeAssignmentPayload? = null
        private set
    /** Highest assignment generation seen; never decreases, so a replayed older assignment cannot reinstate a host. */
    private var generationWatermark: Long? = null

    @get:Synchronized val counters: Counters get() = Counters(forwarded, duplicates, expired, conflicts, dropped)

    /** Every GOS1 frame the bridge's upstream lanes deliver. */
    @Synchronized
    fun onUpstreamFrame(lane: SessionLane, frame: ByteArray, receivedAtMilliseconds: Long, nowMilliseconds: Long) {
        if (lane == SessionLane.ASSET) {
            // Only the manifest is relayed; chunks answer the bridge's own requests and stay out of the dedup window.
            val kind = try { verifier.verify(frame).kind } catch (error: Exception) {
                onRouteFault(lane, "guide frame rejected: ${error.message ?: error.javaClass.simpleName}")
                return
            }
            if (kind != SessionMessageKind.TOUR_PACK_MANIFEST) return
        }
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
                // Lane and kind come from the guide-signed envelope, never from the socket that delivered it.
                val envelope = verifier.verify(frame)
                if (envelope.lane != lane) {
                    onRouteFault(lane, "guide ${envelope.lane} frame arrived on the $lane lane")
                    return
                }
                if (envelope.lane == SessionLane.ASSET) manifestFrame = frame.copyOf()
                forwarded++
                if (envelope.kind == SessionMessageKind.BRIDGE_ASSIGNMENT) observeAssignment(envelope, frame)
                fanOut(envelope.lane, frame)
            }
        }
    }

    /** Registers an island peer after its relay lane handshake; control peers get the cached state first. */
    @Synchronized
    fun attach(lane: SessionLane, writer: RelayChildWriter) {
        val replay = when (lane) {
            SessionLane.CONTROL -> forwarder.snapshotFrames
            SessionLane.ASSET -> listOfNotNull(manifestFrame)
            SessionLane.REALTIME -> emptyList()
        }
        for (frame in replay) {
            if (!writer.enqueue(frame)) { writer.close(); dropped++; return }
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

    /** Reads the guide's assignment to know whether this phone is still the bridge (frame already verified). */
    private fun observeAssignment(sealed: com.aessam.toursession.SealedSessionEnvelope, frame: ByteArray) {
        val opened = opener.open(sealed) as? SessionFrameOpenResult.Opened ?: return
        val value = BridgeAssignmentPayload.decode(opened.envelope.payload)
        val watermark = generationWatermark
        if (watermark != null && java.lang.Long.compareUnsigned(value.generation, watermark) < 0) return
        generationWatermark = value.generation
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
