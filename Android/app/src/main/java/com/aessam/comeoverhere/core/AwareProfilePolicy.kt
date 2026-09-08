package com.aessam.comeoverhere.core

import android.net.wifi.aware.AwarePairingConfig
import android.os.Build
import com.aessam.toursession.SessionCapacityPolicy
import java.io.Closeable
import java.util.UUID

enum class NearbyAwareProfile(val serviceName: String, val requiresPIN: Boolean, val requestTimeoutMilliseconds: Int) {
    ANDROID_PSK("_goh-andr._tcp", true, 15_000),
    SYSTEM_PAIRED("_goh-tour._tcp", false, 35_000),
}

data class AwareProfilePlan(val profiles: Set<NearbyAwareProfile>, val systemUnavailableReason: String?)

/** Pure profile selection: SDK major alone is not proof of the 37.2 API or the radio role. */
object AwareProfilePolicy {
    fun plan(hosting: Boolean, sdkInt: Int, sdkIntFull: Int?, pairingSupported: Boolean,
        offloadMethods: Int, availableDiscoverySessions: Int?): AwareProfilePlan {
        val compatibility = setOf(NearbyAwareProfile.ANDROID_PSK)
        val reason = when {
            sdkInt < 36 || sdkIntFull == null || sdkIntFull < Build.VERSION_CODES_FULL.CINNAMON_BUN_2 ->
                "This Android build lacks system Wi-Fi Aware pairing (SDK 37.2 or later required)."
            !pairingSupported -> "This device does not support system Wi-Fi Aware pairing."
            offloadMethods and (if (hosting) AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_DISPLAY
                else AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD) == 0 ->
                "This device does not support the required system pairing role."
            hosting -> "System-paired hosting needs a public endpoint bootstrap; Android PIN hosting remains available."
            availableDiscoverySessions == null || availableDiscoverySessions < 2 ->
                "There are not enough discovery sessions for both Aware profiles; Android PIN mode is retained."
            else -> null
        }
        return AwareProfilePlan(if (reason == null) compatibility + NearbyAwareProfile.SYSTEM_PAIRED else compatibility, reason)
    }
}

data class AwareNetworkDiagnostic(val profile: NearbyAwareProfile, val networkHandle: Long, val interfaceName: String?)
data class NearbyAwareDiagnostics(
    val sdkInt: Int = 0,
    val sdkIntFull: Int? = null,
    val pairingSupported: Boolean = false,
    val offloadMethods: Int = 0,
    val maximumDataPaths: Int? = null,
    val availableDataPaths: Int? = null,
    val pendingDataPaths: Int = 0,
    val networks: List<AwareNetworkDiagnostic> = emptyList(),
)

/** Shared across all profiles: pending requests consume software reservations before framework
 * counters catch up. Existing paths are never released to make room for another request.
 */
class AwarePathReservations {
    data class Snapshot(val pending: Int, val ownedNetworks: Int)
    private val paths = mutableMapOf<UUID, Long?>()

    @Synchronized fun snapshot(): Snapshot = Snapshot(paths.values.count { it == null }, paths.values.filterNotNull().toSet().size)

    @Synchronized fun reserve(hardwareMaximumPaths: Int?, availablePaths: Int?): Lease {
        val current = snapshot()
        val limit = SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths, availablePaths, current.ownedNetworks, 0)
            ?: throw IllegalStateException("Aware path capacity is unknown; retry after resource discovery")
        check(current.ownedNetworks + current.pending < limit) { "Aware capacity reached; existing guests were kept connected" }
        val id = UUID.randomUUID()
        paths[id] = null
        return Lease(this, id)
    }

    @Synchronized private fun established(id: UUID, networkHandle: Long) {
        if (id in paths) paths[id] = networkHandle
    }

    @Synchronized private fun release(id: UUID) { paths.remove(id) }

    class Lease internal constructor(private val owner: AwarePathReservations, private val id: UUID) : Closeable {
        fun established(networkHandle: Long) = owner.established(id, networkHandle)
        override fun close() = owner.release(id)
    }
}
