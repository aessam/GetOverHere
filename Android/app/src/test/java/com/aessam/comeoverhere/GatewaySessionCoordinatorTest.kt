package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.GatewayWiredInterface
import com.aessam.comeoverhere.core.NearbyAwareState
import com.aessam.comeoverhere.core.NearbyAwareSettings
import com.aessam.comeoverhere.core.WiredInterfaceAddress
import com.aessam.comeoverhere.core.WiredRouteDiagnostic
import com.aessam.comeoverhere.service.GatewayBranchInterface
import com.aessam.comeoverhere.service.GatewayRole
import com.aessam.comeoverhere.service.GatewaySessionCoordinator
import com.aessam.comeoverhere.service.GatewayState
import com.aessam.comeoverhere.service.GatewayTourContext
import com.aessam.comeoverhere.service.GatewayDiscoveryOwnership
import com.aessam.comeoverhere.service.ListenState
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.GatewayPairingMessage
import com.aessam.toursession.GatewayPairingRole
import com.aessam.toursession.GatewayProtocol
import com.aessam.toursession.GatewayRoomDescriptor
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.util.UUID

/** Exercises the production coordinator with controlled native callback timing, not radio evidence. */
@OptIn(ExperimentalCoroutinesApi::class)
class GatewaySessionCoordinatorTest {
    @Test fun nativeRecoveryOwnsRetryAndExhaustionIsVisibleWithoutSecondRetryLoop() = runTest {
        val h = Fixture(this)
        h.wired.automaticRecoveryEnabled = true
        h.enrollCompanion(); runCurrent()
        h.wired.descriptor(h.descriptor); runCurrent()
        h.wired.descriptor(null)
        h.wired.onError?.invoke("Injected native route failure")
        h.wired.onRecoveryChanged?.invoke(com.aessam.comeoverhere.core.GatewayRecoveryState.WAITING)
        runCurrent()
        assertEquals(GatewayState.CONNECTING, h.coordinator.status.value.state)
        advanceTimeBy(30_000); runCurrent()
        assertEquals(0, h.wired.connects)
        h.wired.onRecoveryChanged?.invoke(com.aessam.comeoverhere.core.GatewayRecoveryState.EXHAUSTED)
        runCurrent()
        assertEquals(GatewayState.EXHAUSTED, h.coordinator.status.value.state)
        assertEquals("Injected native route failure", h.coordinator.status.value.error)
        h.coordinator.connectCompanion().join(); runCurrent()
        assertEquals(1, h.wired.connects)
    }

    @Test fun guideGatewayEnablesOriginalBranchUntilTourEndsEvenAfterCompanionRemoval() = runTest {
        val h = Fixture(this, guide = true)
        assertTrue(!h.guideAware.enabledPreference)
        h.coordinator.beginGuide(h.address).join(); runCurrent()
        assertTrue(h.guideAware.enabledPreference)
        assertEquals(0, h.branch.starts)
        h.coordinator.stop(); runCurrent()
        assertTrue("Removing USB companion must not stop local Android listeners", h.guideAware.enabledPreference)
        h.listenState.value = ListenState.IDLE; runCurrent()
        assertTrue(!h.guideAware.enabledPreference)
    }

    @Test fun companionStopRestoresOwnedDiscoveryPreferences() = runTest {
        val h = Fixture(this)
        h.bluetoothEnabled = true; h.guideAware.setEnabled(true)
        h.enrollCompanion(); runCurrent()
        assertTrue(!h.bluetoothEnabled && !h.guideAware.enabledPreference)
        h.coordinator.stop(); runCurrent()
        assertTrue(h.bluetoothEnabled && h.guideAware.enabledPreference)
    }

    @Test fun priorAwarePreferenceSurvivesFailedRadioStateAndRepeatedGuideEnrollment() = runTest {
        val h = Fixture(this, guide = true)
        h.guideAware.setEnabled(true) // Preference true, but simulated radio state remains unavailable/off.
        h.coordinator.beginGuide(h.address).join(); runCurrent()
        h.coordinator.stop(); runCurrent()
        h.coordinator.beginGuide(h.address).join(); runCurrent()
        h.listenState.value = ListenState.IDLE; runCurrent()
        assertTrue(h.guideAware.enabledPreference)
    }

    @Test fun guideDiagnosticsUseOriginalTourOwnerRatherThanCompanionProxy() = runTest {
        val h = Fixture(this, guide = true)
        h.guideAwareState.value = NearbyAwareState(enabled = true, hosting = true, pin = "123456")
        h.coordinator.beginGuide(h.address).join(); runCurrent()
        assertEquals("123456", h.coordinator.awareState.value.pin)
        assertTrue(h.coordinator.awareState.value.hosting)
        assertEquals(0, h.branch.starts)
    }

    @Test fun guideTourEndingDuringNativeOfferCannotEnableOrPublishStaleBranch() = runTest {
        val h = Fixture(this, guide = true)
        h.wired.duringOffer = { h.listenState.value = ListenState.IDLE }
        h.coordinator.beginGuide(h.address).join(); runCurrent()
        assertEquals(GatewayRole.NONE, h.coordinator.status.value.role)
        assertTrue(!h.guideAware.enabledPreference)
        assertNull(h.coordinator.status.value.enrollmentQR)
        assertTrue(h.wired.stops > 0)
    }

    @Test fun stopDuringOfferCannotCommitOrReactivateNativeAssociation() = runTest {
        val h = Fixture(this, guide = true)
        h.wired.duringOffer = { h.coordinator.stop() }
        h.coordinator.beginGuide(h.address).join(); runCurrent()
        assertEquals(GatewayRole.NONE, h.coordinator.status.value.role)
        assertTrue(h.wired.stops >= 1)
        assertNull(h.coordinator.status.value.enrollmentQR)
    }

    @Test fun confirmedButNeverConnectedGuideStillExpiresWhenQRHidden() = runTest {
        val h = Fixture(this, guide = true)
        h.enrollGuide()
        assertNull(h.coordinator.status.value.enrollmentQR)
        advanceTimeBy(120_001); runCurrent()
        assertEquals(GatewayRole.NONE, h.coordinator.status.value.role)
        assertTrue(h.coordinator.status.value.error.orEmpty().contains("expired"))
    }

    @Test fun authenticatedAssociationAndReconnectRemainValidAfterEnrollmentDeadline() = runTest {
        val h = Fixture(this, guide = true)
        h.enrollGuide()
        h.wired.connected(true); runCurrent()
        advanceTimeBy(120_001); runCurrent()
        assertEquals(GatewayState.CONNECTED, h.coordinator.status.value.state)
        h.wired.connected(false); runCurrent()
        h.wired.connected(true); runCurrent()
        assertEquals(GatewayState.CONNECTED, h.coordinator.status.value.state)
        assertEquals(GatewayRole.GUIDE, h.coordinator.status.value.role)
    }

    @Test fun repeatedHeartbeatDoesNotRestartFailedBranchOrEraseItsError() = runTest {
        val h = Fixture(this)
        h.enrollCompanion()
        h.wired.descriptor(h.descriptor); runCurrent()
        h.branch.onError?.invoke("Aware unavailable while tethering"); runCurrent()
        repeat(10) { h.wired.descriptor(h.descriptor) }; runCurrent()
        assertEquals(1, h.branch.starts)
        assertEquals("Aware unavailable while tethering", h.coordinator.status.value.branchError)
        assertEquals(GatewayState.CONNECTED, h.coordinator.status.value.state)
        h.coordinator.retryAndroidBranch()
        assertEquals(2, h.branch.starts)
    }

    @Test fun queuedOldDescriptorCannotReopenBranchAfterStop() = runTest {
        val h = Fixture(this)
        h.enrollCompanion()
        h.wired.descriptor(h.descriptor)
        h.coordinator.stop(); runCurrent()
        assertEquals(GatewayRole.NONE, h.coordinator.status.value.role)
        assertEquals(0, h.branch.starts)
        assertNull(h.coordinator.activeRoomID())
    }

    @Test fun synchronousFirstDescriptorCannotBeOverwrittenByConnectingResult() = runTest {
        val h = Fixture(this)
        h.enrollCompanion()
        h.wired.duringConnect = { h.wired.descriptor(h.descriptor) }
        h.coordinator.connectCompanion().join(); runCurrent()
        assertEquals(GatewayState.CONNECTED, h.coordinator.status.value.state)
        assertNull(h.coordinator.status.value.enrollmentQR)
        assertEquals("Tour", h.coordinator.status.value.roomName)
    }

    @Test fun cableLossWithdrawsBranchAndMakesFiveBoundedSameAddressRetries() = runTest {
        val h = Fixture(this)
        h.enrollCompanion(); h.wired.descriptor(h.descriptor); runCurrent()
        h.wired.descriptor(null); runCurrent()
        assertNull(h.coordinator.activeRoomID())
        assertTrue(h.branch.stops > 0)
        advanceTimeBy(12_000); runCurrent()
        assertEquals(5, h.wired.connects)
        assertTrue(h.coordinator.status.value.error.orEmpty().contains("exhausted"))
    }

    @Test fun guideTourEndingRemovesCompanionAssociation() = runTest {
        val h = Fixture(this, guide = true)
        h.enrollGuide()
        h.listenState.value = ListenState.IDLE; runCurrent()
        assertEquals(GatewayRole.NONE, h.coordinator.status.value.role)
        assertTrue(h.wired.stops > 0)
    }

    private class Fixture(val test: TestScope, guide: Boolean = false) {
        val address = WiredInterfaceAddress("lo", InetAddress.getByName("127.0.0.1"), 8)
        val record = BluetoothRoomRecord(UUID.randomUUID(), UUID.randomUUID(), "Tour", true, false, 2)
        val descriptor = GatewayRoomDescriptor(1, 1, record, ByteArray(65) { if (it == 0) 4 else 1 })
        val listenState = MutableStateFlow(if (guide) ListenState.BROADCASTING else ListenState.IDLE)
        var bluetoothEnabled = false
        val guideAwareState = MutableStateFlow(NearbyAwareState())
        val guideAware = object : NearbyAwareSettings {
            override val state = guideAwareState
            override var enabledPreference = false
            override fun setEnabled(enabled: Boolean) { enabledPreference = enabled }
            override fun pair(peerID: String, pin: String) = Unit
        }
        val discovery = GatewayDiscoveryOwnership(guideAware, { bluetoothEnabled }, { bluetoothEnabled = it })
        val tour = object : GatewayTourContext {
            override val listenState = this@Fixture.listenState
            override val activeRoomID: String? get() = if (guide) record.roomID.toString() else null
            override val guideAwareState = guideAware.state
            override fun descriptor() = if (guide) this@Fixture.descriptor else null
            override fun setCompanionGuard(guard: () -> Boolean) = Unit
            override fun suspendDiscovery() = discovery.suspend()
            override fun resumeDiscovery() = discovery.resume()
            override fun enableGuideDiscovery() = discovery.beginGuide()
            override fun endGuideDiscovery() = discovery.endGuide()
        }
        val branch = ControlledBranch()
        val wired = ControlledWired { offer() }
        val coordinator = GatewaySessionCoordinator(tour, test.backgroundScope, wired, branch,
            StandardTestDispatcher(test.testScheduler), { 1_000L + test.testScheduler.currentTime }, { listOf(address) })
        fun offer() = GatewayPairingMessage(GatewayPairingRole.OFFER, UUID.randomUUID(), record.roomID, record.guideID,
            121_000L, ByteArray(32) { 1 }, ByteArray(32) { 3 }, ByteArray(32) { 1 }, "127.0.0.1", GatewayProtocol.PORT)
        suspend fun enrollGuide() {
            coordinator.beginGuide(address).join()
            val token = GatewayPairingMessage.fromQR(requireNotNull(coordinator.status.value.enrollmentQR))
            coordinator.scanEnrollment(token.copy(role = GatewayPairingRole.RESPONSE,
                certificateFingerprint = ByteArray(32) { 2 }, host = "", port = 0).qrText(), null).join()
            coordinator.confirmCompanion().join()
        }
        suspend fun enrollCompanion() { coordinator.scanEnrollment(offer().qrText(), address).join() }
    }

    private class ControlledBranch : GatewayBranchInterface {
        override val state = MutableStateFlow(NearbyAwareState())
        override var onError: ((String) -> Unit)? = null
        var starts = 0; var stops = 0
        override fun publish(record: BluetoothRoomRecord) = Unit
        override fun start() { starts++ }
        override fun stop() { stops++ }
    }
    private class ControlledWired(private val make: () -> GatewayPairingMessage) : GatewayWiredInterface {
        override var automaticRecoveryEnabled = false
        override var onRecoveryChanged: ((com.aessam.comeoverhere.core.GatewayRecoveryState) -> Unit)? = null
        override var onDescriptor: ((GatewayRoomDescriptor?) -> Unit)? = null
        override var onError: ((String) -> Unit)? = null
        override var onConnected: ((Boolean) -> Unit)? = null
        override var isConnected = false
        override val routeDescription = "test-only controlled native boundary"
        var duringOffer: (() -> Unit)? = null; var duringConnect: (() -> Unit)? = null
        var connects = 0; var stops = 0
        override fun routeSnapshot(): WiredRouteDiagnostic? = null
        override fun makeOffer(record: BluetoothRoomRecord, key: ByteArray, address: WiredInterfaceAddress,
                               current: () -> GatewayRoomDescriptor?): GatewayPairingMessage { duringOffer?.invoke(); return make() }
        override fun answerOffer(message: GatewayPairingMessage, address: WiredInterfaceAddress) =
            message.copy(role = GatewayPairingRole.RESPONSE, certificateFingerprint = ByteArray(32) { 2 }, host = "", port = 0)
        override fun confirmResponse(message: GatewayPairingMessage) = Unit
        override fun startCompanion() { connects++; duringConnect?.invoke() }
        override fun stop() { stops++; isConnected = false }
        fun connected(value: Boolean) { isConnected = value; onConnected?.invoke(value) }
        fun descriptor(value: GatewayRoomDescriptor?) { isConnected = value != null; onDescriptor?.invoke(value) }
    }
}
