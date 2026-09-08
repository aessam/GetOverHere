package com.aessam.comeoverhere

import android.net.wifi.aware.AwarePairingConfig
import android.os.Build
import com.aessam.comeoverhere.core.AwarePathReservations
import com.aessam.comeoverhere.core.AwareProfilePolicy
import com.aessam.comeoverhere.core.NearbyAwareProfile
import com.aessam.comeoverhere.core.NearbyGuestRoute
import com.aessam.comeoverhere.core.NearbyRoomMetadataMismatch
import com.aessam.comeoverhere.core.NearbyRoomMetadataPolicy
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.SessionTransportRoute
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AwareProfilePolicyTest {
    private val keypad = AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD
    private val display = AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_DISPLAY
    private val supported = Build.VERSION_CODES_FULL.CINNAMON_BUN_2

    @Test fun reachableMetadataMustMatchSelectedRoomGuideAndAdmissionVersion() {
        val room = UUID.randomUUID(); val guide = UUID.randomUUID()
        val record = BluetoothRoomRecord(room, guide, "Tour", false, true, 2)
        NearbyRoomMetadataPolicy.validate(record, room, guide)
        assertEquals(NearbyRoomMetadataMismatch.Reason.ROOM_CHANGED,
            assertThrows(NearbyRoomMetadataMismatch::class.java) {
                NearbyRoomMetadataPolicy.validate(record, UUID.randomUUID(), guide)
            }.reason)
        assertEquals(NearbyRoomMetadataMismatch.Reason.GUIDE_CHANGED,
            assertThrows(NearbyRoomMetadataMismatch::class.java) {
                NearbyRoomMetadataPolicy.validate(record, room, UUID.randomUUID())
            }.reason)
        assertEquals(NearbyRoomMetadataMismatch.Reason.ADMISSION_VERSION_UNSUPPORTED,
            assertThrows(NearbyRoomMetadataMismatch::class.java) {
                NearbyRoomMetadataPolicy.validate(record.copy(admissionVersion = 1), room, guide)
            }.reason)
        assertTrue(NearbyRoomMetadataMismatch(NearbyRoomMetadataMismatch.Reason.ROOM_CHANGED).message!!.contains("room list"))
        assertTrue(NearbyRoomMetadataMismatch(NearbyRoomMetadataMismatch.Reason.GUIDE_CHANGED).message!!.contains("confirm"))
        assertTrue(NearbyRoomMetadataMismatch(NearbyRoomMetadataMismatch.Reason.ADMISSION_VERSION_UNSUPPORTED).message!!.contains("Update both apps"))
    }

    @Test fun exactRuntimeHardwareRoleAndDiscoveryResourcesGateSystemProfile() {
        val compatible = setOf(NearbyAwareProfile.ANDROID_PSK)
        for ((sdk, full) in listOf(35 to null, 36 to 3_600_000, 37 to 3_700_000, 37 to 3_700_001)) {
            assertEquals(compatible, AwareProfilePolicy.plan(false, sdk, full, true, keypad, 2).profiles)
        }
        assertEquals(compatible, AwareProfilePolicy.plan(false, 37, supported, false, keypad, 2).profiles)
        assertEquals(compatible, AwareProfilePolicy.plan(false, 37, supported, true, display, 2).profiles)
        assertEquals(compatible, AwareProfilePolicy.plan(false, 37, supported, true, keypad, 1).profiles)
        assertEquals(compatible, AwareProfilePolicy.plan(false, 37, supported, true, keypad, null).profiles)
        val both = AwareProfilePolicy.plan(false, 37, supported, true, keypad, 2)
        assertEquals(NearbyAwareProfile.entries.toSet(), both.profiles)
        assertEquals(null, both.systemUnavailableReason)
    }

    @Test fun noUndocumentedSystemPublisherOrDummyPasswordFallback() {
        val plan = AwareProfilePolicy.plan(true, 37, supported, true, display or keypad, 8)
        assertEquals(setOf(NearbyAwareProfile.ANDROID_PSK), plan.profiles)
        assertTrue(requireNotNull(plan.systemUnavailableReason).contains("endpoint bootstrap"))
        assertFalse(NearbyAwareProfile.SYSTEM_PAIRED.requiresPIN)
        assertTrue(NearbyAwareProfile.ANDROID_PSK.requiresPIN)
        assertEquals("_goh-tour._tcp", NearbyAwareProfile.SYSTEM_PAIRED.serviceName)
        assertEquals("_goh-andr._tcp", NearbyAwareProfile.ANDROID_PSK.serviceName)
        assertTrue(NearbyAwareProfile.SYSTEM_PAIRED.requestTimeoutMilliseconds >= 30_000)
    }

    @Test fun pendingReservationsAreSharedAndNeverEvictEstablishedPeers() {
        val owner = AwarePathReservations()
        val first = owner.reserve(2, 2)
        val second = owner.reserve(2, 2)
        assertEquals(AwarePathReservations.Snapshot(2, 0), owner.snapshot())
        assertThrows(IllegalStateException::class.java) { owner.reserve(2, 2) }
        first.established(100)
        second.established(101)
        assertEquals(AwarePathReservations.Snapshot(0, 2), owner.snapshot())
        assertThrows(IllegalStateException::class.java) { owner.reserve(2, 0) }
        assertEquals(AwarePathReservations.Snapshot(0, 2), owner.snapshot())
        second.close()
        second.close()
        val replacement = owner.reserve(2, 1)
        assertEquals(AwarePathReservations.Snapshot(1, 1), owner.snapshot())
        replacement.close()
        first.close()
        assertEquals(AwarePathReservations.Snapshot(0, 0), owner.snapshot())
    }

    @Test fun unknownAndInvalidSnapshotsDoNotInventAnEightPathCapacity() {
        val owner = AwarePathReservations()
        assertThrows(IllegalStateException::class.java) { owner.reserve(null, null) }
        assertThrows(Exception::class.java) { owner.reserve(-1, 0) }
        assertThrows(Exception::class.java) { owner.reserve(1, 2) }
        val single = owner.reserve(1, 1)
        assertNotNull(single)
        assertThrows(IllegalStateException::class.java) { owner.reserve(1, 1) }
        single.close()
    }

    @Test fun adapterEndpointCannotPretendToBeLanAndOwnershipIsExplicit() {
        val room = UUID.randomUUID()
        val owner = UUID.randomUUID()
        val route = NearbyGuestRoute("127.0.0.1", SessionTransportRoute.BLUETOOTH, room, owner)
        assertEquals(SessionTransportRoute.BLUETOOTH, route.transport)
        assertEquals(owner, route.routeID)
        assertEquals(room, route.roomID)
        assertThrows(IllegalArgumentException::class.java) {
            NearbyGuestRoute("127.0.0.1", SessionTransportRoute.LOCAL_LAN, room, owner)
        }
        for (invalid in listOf("", "localhost", "192.168.1.10", "::1", "127.0.0.2")) {
            assertThrows(IllegalArgumentException::class.java) {
                NearbyGuestRoute(invalid, SessionTransportRoute.WIFI_AWARE, room, owner)
            }
        }
    }
}
