package com.aessam.comeoverhere.core

import android.util.Log
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.BridgeAssignmentPayload
import com.aessam.toursession.GatewayLane
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.RelayHostAdvert
import com.aessam.toursession.RelayUpstreamRecord
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionLane
import java.io.File
import java.net.InetAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.Executors

/** Publishes the island room and routes accepted island connections through [GuideLaneConnector] (ADR-081 P1). */
interface IslandAdvertiserInterface {
    fun start(record: BluetoothRoomRecord, connector: GuideLaneConnector)
    fun stop()
}

/**
 * The bridge side of a cross-island tour on an ordinary guest (ADR-081 P1 step 3). Every guide frame the guest's
 * realtime/control lanes open is fed to [RelayHub]. When the guide's signed `bridgeAssignment` names this guest, the
 * island starts: one loopback [RelayLaneServer] per media lane, and an island advertiser whose admission lane goes to
 * the guest's own nearby bridge (127.0.0.1:50003), which tunnels it to the guide. Another assignment, [stop], or
 * leaving the tour closes the island. Upstream lanes and their ports are untouched, so guest and island coexist.
 */
class RelayIslandHost(
    private val bridgeID: UUID,
    private val sessionID: UUID,
    private val guideID: UUID,
    private val credential: SessionCredential,
    verifier: GuideFrameVerifier,
    /** The upstream room record; the island republishes it with this bridge's [RelayHostAdvert]. */
    private val upstreamRecord: BluetoothRoomRecord,
    private val advertiser: IslandAdvertiserInterface,
    private val assetFile: (String) -> File?,
    /** W5: carries island guests' advisory frames to the guide on this guest's own control lane. */
    private val forwardUpstream: (RelayUpstreamRecord) -> Unit = {},
    private val admissionPort: Int = GatewayLane.ADMISSION.localPort!!,
    private val now: () -> Long = System::currentTimeMillis,
) : AutoCloseable {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "relay-island").apply { isDaemon = true } }
    private val servers = mutableMapOf<SessionLane, RelayLaneServer>()
    private var islandGeneration: Long? = null
    @Volatile private var closed = false

    val hub = RelayHub(bridgeID, verifier, credential,
        onRouteFault = { lane, reason -> Log.e(TAG, "Relay route fault on $lane: $reason") },
        // Called under the hub lock: tear down on the island thread, never inline.
        onIslandRevoked = { value -> executor.execute { stopIsland("guide assigned ${value.bridgeID} (generation ${value.generation})") } })

    /** Raw GOS1 bytes of a guide frame the guest just opened on [lane]. */
    fun onUpstreamFrame(lane: SessionLane, frame: ByteArray) {
        if (closed) return
        val time = now()
        hub.onUpstreamFrame(lane, frame, time, time)
        val assigned = hub.assignment ?: return
        if (assigned.generation != islandGeneration) executor.execute { startIsland(assigned) }
    }

    /** Lane ports while the island runs (tests and diagnostics). */
    @Synchronized fun lanePorts(): Map<SessionLane, Int> = servers.mapValues { it.value.port }

    override fun close() {
        closed = true
        executor.execute { stopIsland("bridge stopped") }
        executor.shutdown()
    }

    @Synchronized private fun startIsland(assigned: BridgeAssignmentPayload) {
        if (closed || hub.assignment?.generation != assigned.generation || islandGeneration == assigned.generation) return
        if (servers.isEmpty()) {
            try {
                listOf(SessionLane.REALTIME, SessionLane.CONTROL, SessionLane.ASSET).forEach { lane ->
                    servers[lane] = RelayLaneServer(lane, credential, sessionID, guideID, bridgeID, hub, assetFile, forwardUpstream)
                }
            } catch (error: Exception) {
                Log.e(TAG, "Relay island listeners failed (${error.javaClass.simpleName}: ${error.message})")
                stopIsland("listeners failed")
                return
            }
        }
        islandGeneration = assigned.generation
        val record = upstreamRecord.copy(relayHost = RelayHostAdvert(bridgeID, assigned.generation))
        advertiser.start(record) { lane -> connect(lane) }
        Log.i(TAG, "Relay island up: generation ${assigned.generation}, ports ${lanePorts()}")
    }

    @Synchronized private fun stopIsland(reason: String) {
        if (servers.isEmpty() && islandGeneration == null) return
        advertiser.stop()
        servers.values.forEach(RelayLaneServer::close)
        servers.clear()
        hub.closeIsland()
        islandGeneration = null
        Log.i(TAG, "Relay island down: $reason")
    }

    private fun connect(lane: GatewayLane): NearbyByteConnection {
        val port = when (lane) {
            GatewayLane.REALTIME -> lanePorts()[SessionLane.REALTIME]
            GatewayLane.CONTROL -> lanePorts()[SessionLane.CONTROL]
            GatewayLane.ASSET -> lanePorts()[SessionLane.ASSET]
            GatewayLane.ADMISSION -> admissionPort
            GatewayLane.HUB_CONTROL -> null
        } ?: throw IllegalStateException("relay island has no $lane lane")
        return NearbyTCPConnection(Socket(InetAddress.getLoopbackAddress(), port))
    }

    private companion object { const val TAG = "RelayIslandHost" }
}

/** Island advertiser over Wi-Fi Aware; a separate transport so the guest's own Aware mode is not changed. */
@androidx.annotation.RequiresApi(android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class AwareIslandAdvertiser(
    private val context: android.content.Context,
    private val connectionBudget: NearbyConnectionBudget = NearbyConnectionBudget.sharedApp,
) : IslandAdvertiserInterface {
    private var transport: WiFiAwareRoomTransport? = null

    @Synchronized override fun start(record: BluetoothRoomRecord, connector: GuideLaneConnector) {
        val current = transport ?: WiFiAwareRoomTransport(context, connectionBudget, connector).also { created ->
            created.onError = { message -> Log.e("AwareIsland", message) }
            transport = created
        }
        current.publish(record)
        current.setMode(BluetoothDiscoveryMode.ADVERTISING)
    }

    @Synchronized override fun stop() {
        transport?.setMode(BluetoothDiscoveryMode.OFF)
        transport?.publish(null)
        transport = null
    }
}
