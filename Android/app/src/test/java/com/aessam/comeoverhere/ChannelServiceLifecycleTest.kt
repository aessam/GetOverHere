package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.AudioSessionEvent
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.Channel
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.core.NetworkCoordinator
import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionControlEvent
import com.aessam.comeoverhere.service.ChannelService
import com.aessam.comeoverhere.service.AudioRuntimeState
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.ListenState
import com.aessam.comeoverhere.service.SessionConnectionState
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.comeoverhere.service.TourContentStore
import com.aessam.comeoverhere.service.TourControlService
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.SessionRole
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/**
 * ChannelService lifecycle proofs (G4): FND-2 startup ordering and rollback, FND-6 discovery-driven
 * reconfiguration, FND-8 terminal paths and the asynchronous leave flush, FND-13 counts and warnings.
 *
 * The credential stretch runs on a real `Dispatchers.Default` thread (ADR-042), so every step after
 * `createChannel`/`joinChannel` polls with a real wait before emitting fake lane events (RSK-4). The
 * reconnect `delay`s run on the virtual scheduler and are driven with `advanceTimeBy` + `runCurrent`;
 * `advanceUntilIdle` is never used because `start()` installs a periodic broadcast loop.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChannelServiceLifecycleTest {
    @Test fun canceledQueuedJoinCannotRestoreConnectingStateOrStartAdmission() {
        val admission = RouteAdmission()
        val h = Harness(admissionOverride = admission, queuedDispatch = true)
        try {
            h.scheduler.runCurrent()
            val room = Channel(UUID.randomUUID().toString(), "Canceled tour", 0.0, UUID.randomUUID().toString(),
                audioHostIP = "10.0.0.1", roomAdmissionVersion = 2)
            h.service.joinChannel(room, TOUR_CODE)
            h.service.leaveChannel()
            h.scheduler.runCurrent()
            assertEquals(SessionConnectionState.IDLE, h.service.connectionState.value)
            assertEquals(com.aessam.comeoverhere.service.RoomJoinStage.IDLE, h.service.joinStage.value)
            assertNull(h.service.activeChannelID.value)
            assertTrue(admission.calls.isEmpty())
            assertEquals(0, h.controlPlane.nearbyPrepareCalls)
            assertEquals(0, h.control.startGuestCalls)
            assertEquals(0, h.audioPlane.startListeningCalls)
            assertTrue(h.uncaught.isEmpty())
        } finally { h.close() }
    }

    @Test fun queuedOldConnectedEventCannotCancelSuspendedNearbyRecovery() {
        val base = LifecycleControlPlane().apply { nearbyAvailable = true }
        val release = CompletableDeferred<Unit>()
        var hold = false
        var entered = 0
        val routed = object : com.aessam.comeoverhere.core.ControlPlane by base,
            com.aessam.comeoverhere.core.NearbyRouteControl by base {
            override suspend fun prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID): com.aessam.comeoverhere.core.NearbyGuestRoute {
                val prepared = base.prepareNearbyGuest(roomID, expectedGuideID)
                if (hold) { entered++; release.await() }
                return prepared
            }
        }
        val h = Harness(controlPlane = base, coordinatorControlPlane = routed, queuedDispatch = true)
        try {
            val room = Channel(UUID.randomUUID().toString(), "Nearby tour", 0.0, UUID.randomUUID().toString(),
                audioHostIP = null, roomAdmissionVersion = 2)
            h.service.start(); h.scheduler.runCurrent()
            base.emit(announce(room, null)); h.scheduler.runCurrent()
            h.service.joinChannel(room, TOUR_CODE)
            awaitCondition("queued guest lanes") { h.scheduler.runCurrent(); h.control.startGuestCalls == 1 }
            h.control.emit(SessionControlEvent.Connected); h.scheduler.runCurrent()
            assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
            hold = true
            h.control.emit(SessionControlEvent.Disconnected); h.scheduler.runCurrent()
            h.scheduler.advanceTimeBy(1)
            // Forward while the old control run still exists, behind the due reconnect task.
            h.control.emit(SessionControlEvent.Connected)
            h.scheduler.runCurrent()
            assertEquals(1, entered)
            assertEquals(SessionConnectionState.RECONNECTING, h.service.connectionState.value)
            assertEquals(1, h.control.startGuestCalls)
            release.complete(Unit); h.scheduler.runCurrent()
            assertEquals(2, h.control.startGuestCalls)
            assertEquals(SessionConnectionState.CONNECTING, h.service.connectionState.value)
            h.control.emit(SessionControlEvent.Connected); h.scheduler.runCurrent()
            assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
            assertTrue(h.uncaught.isEmpty())
        } finally { release.complete(Unit); h.close() }
    }

    @Test fun unreachableLANFallsBackOnceToMatchingNearbyForEveryLane() {
        val admission = RouteAdmission()
        val h = Harness(admissionOverride = admission)
        try {
            admission.unreachableLAN = true
            h.controlPlane.nearbyAvailable = true
            val room = h.discoverAndJoin()
            h.connectGuest()
            assertEquals(listOf("10.0.0.1", "127.0.0.1"), admission.calls.map { it.host })
            assertEquals(1, h.controlPlane.nearbyPrepareCalls)
            assertTrue(admission.calls.all { it.room == UUID.fromString(room.id) &&
                it.guide == UUID.fromString(room.createdBy) && it.code == TOUR_CODE })
            assertEquals(com.aessam.toursession.SessionTransportRoute.BLUETOOTH, h.service.activeTransportRoute.value)
            assertNotNull(h.controlPlane.activeNearbyGuestRoute)
            assertEquals("127.0.0.1", h.control.startGuestHostIPs.last())
            assertEquals("127.0.0.1", h.asset.hostIP)
            assertEquals(1, h.audioPlane.startListeningCalls)
        } finally { h.close() }
    }

    @Test fun bluetoothOnlyNeverAdmitsOrReconnectsOverAdvertisedLAN() {
        val admission = RouteAdmission()
        val h = Harness(admissionOverride = admission)
        try {
            h.service.setRoutePolicy(com.aessam.toursession.AllowedTransportPolicy.BLUETOOTH_ONLY)
            h.controlPlane.nearbyAvailable = true
            val room = h.discoverAndJoin("10.0.0.1")
            h.connectGuest()
            assertEquals(listOf("127.0.0.1"), admission.calls.map { it.host })
            assertEquals(com.aessam.toursession.SessionTransportRoute.BLUETOOTH, h.service.activeTransportRoute.value)
            val starts = h.control.startGuestCalls
            h.controlPlane.emit(announce(room, "10.0.0.99"))
            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(2); h.scheduler.runCurrent()
            awaitCondition("bluetooth reconnect") { h.scheduler.runCurrent(); h.control.startGuestCalls > starts }
            assertEquals(listOf("127.0.0.1"), admission.calls.map { it.host })
            assertTrue(h.control.startGuestHostIPs.all { it == "127.0.0.1" })
            assertEquals("127.0.0.1", h.asset.hostIP)
            assertEquals(com.aessam.toursession.SessionTransportRoute.BLUETOOTH, h.service.activeTransportRoute.value)
        } finally { h.close() }
    }

    @Test fun bluetoothOnlyCannotJoinLANOnlyOrAwareRooms() {
        val admission = RouteAdmission()
        val h = Harness(admissionOverride = admission)
        try {
            h.service.setRoutePolicy(com.aessam.toursession.AllowedTransportPolicy.BLUETOOTH_ONLY)
            h.service.start()
            val lanOnly = Channel(UUID.randomUUID().toString(), "Tour", 0.0, UUID.randomUUID().toString(),
                audioHostIP = "10.0.0.1", roomAdmissionVersion = 2)
            assertEquals(false, h.service.canJoin(lanOnly))
            h.controlPlane.nearbyAvailable = true
            h.controlPlane.nearbyTransport = com.aessam.toursession.SessionTransportRoute.WIFI_AWARE
            assertEquals(false, h.service.canJoin(lanOnly))
            h.service.joinChannel(lanOnly, TOUR_CODE)
            awaitCondition("forbidden routes fail") { h.service.connectionState.value == SessionConnectionState.FAILED }
            assertTrue(admission.calls.isEmpty())
            assertEquals(0, h.controlPlane.nearbyPrepareCalls)
            assertEquals(0, h.audioPlane.startListeningCalls)
        } finally { h.close() }
    }

    @Test fun terminalLANAdmissionNeverFallsThroughToNearby() {
        listOf(com.aessam.toursession.RoomAdmissionException("Wrong code"),
            com.aessam.toursession.RoomAdmissionV2Exception(com.aessam.toursession.RoomAdmissionV2Exception.Reason.WRONG_GUIDE),
            com.aessam.toursession.RoomAdmissionV2Exception(com.aessam.toursession.RoomAdmissionV2Exception.Reason.INCOMPATIBLE_VERSION),
            IllegalArgumentException("Malformed challenge"), java.io.EOFException("Reply ended after request")).forEach { failure ->
            val admission = RouteAdmission().apply { terminalError = failure }
            val h = Harness(admissionOverride = admission)
            try {
                h.controlPlane.nearbyAvailable = true
                val channel = Channel(UUID.randomUUID().toString(), "Tour", 0.0, UUID.randomUUID().toString(),
                    audioHostIP = "10.0.0.1", roomAdmissionVersion = 2)
                h.service.joinChannel(channel, TOUR_CODE)
                awaitCondition("terminal LAN admission") { h.service.connectionState.value == SessionConnectionState.FAILED }
                assertEquals(listOf("10.0.0.1"), admission.calls.map { it.host })
                assertEquals(0, h.controlPlane.nearbyPrepareCalls)
                assertEquals(0, h.audioPlane.startListeningCalls)
            } finally { h.close() }
        }
    }

    @Test fun unreachableNearbyFallbackStopsAfterOneAttempt() {
        val admission = RouteAdmission().apply { unreachableLAN = true; unreachableNearby = true }
        val h = Harness(admissionOverride = admission)
        try {
            h.controlPlane.nearbyAvailable = true
            val channel = Channel(UUID.randomUUID().toString(), "Tour", 0.0, UUID.randomUUID().toString(),
                audioHostIP = "10.0.0.1", roomAdmissionVersion = 2)
            h.service.joinChannel(channel, TOUR_CODE)
            awaitCondition("both routes failed") { h.service.connectionState.value == SessionConnectionState.FAILED }
            assertEquals(listOf("10.0.0.1", "127.0.0.1"), admission.calls.map { it.host })
            assertEquals(1, h.controlPlane.nearbyPrepareCalls)
            assertNull(h.controlPlane.activeNearbyGuestRoute)
            assertEquals(0, h.audioPlane.startListeningCalls)
        } finally { h.close() }
    }

    @Test fun failedNearbyRecoveryDoesNotReopenStaleAdaptersOrSwitchToAdvertisedLAN() {
        val h = Harness()
        try {
            h.controlPlane.nearbyAvailable = true
            val room = h.discoverAndJoin(null)
            h.connectGuest()
            val starts = h.control.startGuestCalls
            h.controlPlane.emit(announce(room, "10.0.0.99"))
            h.controlPlane.nearbyPrepareError = IllegalStateException("Nearby path unavailable")
            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(2); h.scheduler.runCurrent()
            assertNull(h.service.resolvedGuestRoute)
            assertEquals(starts, h.control.startGuestCalls)
            h.service.retryAudio()
            h.controlPlane.emit(announce(room, "10.0.0.100"))
            h.scheduler.runCurrent()
            assertEquals(starts, h.control.startGuestCalls)
            repeat(6) { h.scheduler.advanceTimeBy(100); h.scheduler.runCurrent() }
            awaitCondition("bounded failed nearby recovery") {
                h.scheduler.advanceTimeBy(100); h.scheduler.runCurrent()
                h.service.connectionState.value == SessionConnectionState.FAILED
            }
            assertEquals(starts, h.control.startGuestCalls)
            assertNull(h.service.resolvedGuestRoute)
            assertEquals("127.0.0.1", h.control.startGuestHostIPs.last())
        } finally { h.close() }
    }

    @Test fun nearbyRouteSurvivesLANAnnouncementAndReconnectWithoutReadmission() {
        val admission = RouteAdmission()
        val h = Harness(admissionOverride = admission)
        try {
            h.controlPlane.nearbyAvailable = true
            val room = h.discoverAndJoin(null)
            h.connectGuest()
            val descriptor = requireNotNull(h.service.resolvedGuestRoute)
            val starts = h.control.startGuestCalls
            val stops = h.controlPlane.nearbyStopCalls
            h.controlPlane.emit(announce(room, "10.0.0.99"))
            h.scheduler.runCurrent()
            assertEquals(starts, h.control.startGuestCalls)
            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(2); h.scheduler.runCurrent()
            awaitCondition("nearby reconnect after LAN announcement") { h.scheduler.runCurrent(); h.control.startGuestCalls > starts }
            assertEquals(descriptor, h.service.resolvedGuestRoute)
            assertEquals(stops, h.controlPlane.nearbyStopCalls)
            assertEquals(listOf("127.0.0.1"), admission.calls.map { it.host })
            assertEquals("127.0.0.1", h.control.startGuestHostIPs.last())
            assertEquals("127.0.0.1", h.asset.hostIP)
        } finally { h.close() }
    }

    @Test fun canceledLANAdmissionCannotPrepareNearbyOrMutateReplacementSession() {
        val admission = RouteAdmission()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        admission.beforeJoin = { host ->
            if (host == "10.0.0.1") {
                entered.countDown()
                check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
            }
        }
        admission.unreachableLAN = true
        val h = Harness(admissionOverride = admission)
        try {
            h.controlPlane.nearbyAvailable = true
            val channel = Channel(UUID.randomUUID().toString(), "Old", 0.0, UUID.randomUUID().toString(),
                audioHostIP = "10.0.0.1", roomAdmissionVersion = 2)
            h.service.joinChannel(channel, TOUR_CODE)
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            h.service.leaveChannel()
            h.createGuide()
            val replacement = h.service.activeChannelID.value
            release.countDown()
            awaitCondition("old admission completed") { admission.returned }
            h.scheduler.runCurrent()
            assertEquals(replacement, h.service.activeChannelID.value)
            assertEquals(ListenState.BROADCASTING, h.service.listenState.value)
            assertEquals(0, h.controlPlane.nearbyPrepareCalls)
        } finally { release.countDown(); h.close() }
    }

    @Test fun suspendedNearbyRecoveryIsSingleFlightAndCannotMutateReplacementRoom() {
        val base = LifecycleControlPlane().apply { nearbyAvailable = true }
        val release = CompletableDeferred<Unit>()
        var hold = false
        var entered = 0
        val routed = object : com.aessam.comeoverhere.core.ControlPlane by base,
            com.aessam.comeoverhere.core.NearbyRouteControl by base {
            override suspend fun prepareNearbyGuest(roomID: UUID, expectedGuideID: UUID): com.aessam.comeoverhere.core.NearbyGuestRoute {
                val prepared = base.prepareNearbyGuest(roomID, expectedGuideID)
                if (hold) {
                    entered++
                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { release.await() }
                }
                return prepared
            }
        }
        val h = Harness(controlPlane = base, coordinatorControlPlane = routed)
        try {
            h.discoverAndJoin(null); h.connectGuest()
            hold = true
            val starts = h.control.startGuestCalls
            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(2); h.scheduler.runCurrent()
            assertEquals(1, entered)
            h.service.retryAudio()
            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(1_000); h.scheduler.runCurrent()
            assertEquals(1, entered)
            assertEquals(starts, h.control.startGuestCalls)
            h.service.leaveChannel()
            h.createGuide()
            val replacement = h.service.activeChannelID.value
            release.complete(Unit)
            h.scheduler.runCurrent()
            assertEquals(replacement, h.service.activeChannelID.value)
            assertEquals(ListenState.BROADCASTING, h.service.listenState.value)
            assertNull(h.service.resolvedGuestRoute)
            assertEquals(starts, h.control.startGuestCalls)
        } finally { release.complete(Unit); h.close() }
    }

    @Test fun oldCaptureFinalizerFailureCannotFailReplacementGuideOrGuest() {
        listOf(false, true).forEach { replaceWithGuest ->
            val h = Harness()
            val releaseOld = CompletableDeferred<Unit>()
            try {
                h.engine.captureFlow = flow {
                    try { kotlinx.coroutines.awaitCancellation() }
                    finally {
                        kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                            releaseOld.await()
                            throw IllegalStateException("Old capture finalizer failed")
                        }
                    }
                }
                h.createGuide()
                h.service.leaveChannel()
                h.engine.captureFlow = flow { kotlinx.coroutines.awaitCancellation() }
                if (replaceWithGuest) { h.discoverAndJoin(); h.connectGuest() } else h.createGuide()
                val current = h.service.activeChannelID.value
                val state = h.service.audioRuntimeState.value
                releaseOld.complete(Unit)
                h.scheduler.runCurrent()
                assertEquals(current, h.service.activeChannelID.value)
                assertEquals(state, h.service.audioRuntimeState.value)
                assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
            } finally { releaseOld.complete(Unit); h.close() }
        }
    }

    @Test fun oldAudioRunAuthenticationCallbackCannotFailNewRoom() {
        val h = Harness()
        try {
            h.discoverAndJoin(); h.connectGuest()
            val old = h.audioPlane.capturedEventHandler()
            h.service.leaveChannel()
            val current = h.discoverAndJoin(); h.connectGuest()
            old(AudioSessionEvent.AuthenticationFailed("Old run failed"))
            h.scheduler.runCurrent()
            assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
            assertEquals(current.id, h.service.activeChannelID.value)
        } finally { h.close() }
    }

    @Test fun assetCredentialRejectionIsTerminalAndPreservesPinnedGuide() {
        val h = Harness()
        try {
            h.discoverAndJoin(); h.connectGuest()
            val fingerprint = h.service.guideKeyFingerprint.value
            val starts = h.control.startGuestCalls
            h.asset.emit(SessionAssetEvent.CredentialRejected("Asset credential rejected"))
            awaitCondition("terminal asset rejection") { h.service.connectionState.value == SessionConnectionState.FAILED }
            h.scheduler.advanceTimeBy(60_000); h.scheduler.runCurrent()
            assertEquals(starts, h.control.startGuestCalls)
            assertEquals(fingerprint, h.service.guideKeyFingerprint.value)
        } finally { h.close() }
    }

    @Test fun changedNearbyGuideDuringReconnectIsTerminalWithoutReadmission() {
        val h = Harness()
        try {
            h.controlPlane.nearbyAvailable = true
            h.discoverAndJoin(null); h.connectGuest()
            val starts = h.control.startGuestCalls
            h.controlPlane.nearbyPrepareError = com.aessam.comeoverhere.core.NearbyRoomMetadataMismatch(
                com.aessam.comeoverhere.core.NearbyRoomMetadataMismatch.Reason.GUIDE_CHANGED)
            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(2); h.scheduler.runCurrent()
            awaitCondition("changed nearby guide rejected") { h.scheduler.runCurrent(); h.service.connectionState.value == SessionConnectionState.FAILED }
            h.scheduler.advanceTimeBy(60_000); h.scheduler.runCurrent()
            assertEquals(starts, h.control.startGuestCalls)
            assertNotNull(h.service.guideKeyFingerprint.value)
        } finally { h.close() }
    }

    @Test fun nearbyLoopbackRetainsActualCarrierAndRouteIdentityAcrossReconnect() {
        listOf(com.aessam.toursession.SessionTransportRoute.BLUETOOTH,
            com.aessam.toursession.SessionTransportRoute.WIFI_AWARE).forEach { carrier ->
            val h = Harness()
            try {
                h.controlPlane.nearbyAvailable = true
                h.controlPlane.nearbyTransport = carrier
                val room = h.discoverAndJoin(null)
                h.connectGuest()
                val descriptor = requireNotNull(h.service.resolvedGuestRoute)
                assertEquals(UUID.fromString(room.id), descriptor.roomID)
                assertEquals("127.0.0.1", descriptor.adapterHost)
                assertEquals(carrier, h.service.activeTransportRoute.value)
                val stops = h.controlPlane.nearbyStopCalls
                val starts = h.control.startGuestCalls
                h.control.emit(SessionControlEvent.Disconnected)
                h.scheduler.advanceTimeBy(2); h.scheduler.runCurrent()
                awaitCondition("nearby reconnect") { h.scheduler.runCurrent(); h.control.startGuestCalls > starts }
                assertEquals(descriptor.routeID, h.service.resolvedGuestRoute?.routeID)
                assertEquals(carrier, h.service.activeTransportRoute.value)
                assertEquals(stops, h.controlPlane.nearbyStopCalls)
                h.service.leaveChannel()
                assertNull(h.service.resolvedGuestRoute)
                assertNull(h.service.activeTransportRoute.value)
                assertNull(h.controlPlane.activeNearbyGuestRoute)
            } finally { h.close() }
        }
    }

    @Test fun guideInstallsOneAuthorityInEveryLaneAndShowsItsFingerprint() {
        val h = Harness()
        try {
            h.createGuide()
            val authority = h.audioPlane.configuredAuthentication as com.aessam.comeoverhere.core.SessionGuideAuthentication.Guide
            assertTrue(authority === h.control.configuredAuthentication)
            assertTrue(authority === h.asset.configuredAuthentication)
            val expected = java.security.MessageDigest.getInstance("SHA-256").digest(authority.signer.publicKey)
                .take(6).joinToString("") { "%02X".format(it.toInt() and 255) }.chunked(4).joinToString(" ")
            assertEquals(expected, h.service.guideKeyFingerprint.value)
            h.service.leaveChannel()
            assertNull(h.service.guideKeyFingerprint.value)
        } finally { h.close() }
    }

    @Test fun controlAdmissionDoesNotClaimPlaybackBeforeRendererAcceptsPCM() {
        val h = Harness()
        try {
            h.discoverAndJoin()
            h.connectGuest()
            assertEquals(AudioRuntimeState.STARTING, h.service.audioRuntimeState.value)
            fun statuses() = h.control.sent.filter { it.first == com.aessam.toursession.SessionMessageKind.AUDIO_STATUS }
                .map { com.aessam.toursession.AudioReadinessPayload.decode(it.second).status }
            assertEquals(listOf(com.aessam.toursession.AudioReadinessStatus.WAITING), statuses())
            h.engine.acceptPlayback = false
            h.audioPlane.emitPCM(ByteArray(320))
            assertEquals(AudioRuntimeState.STARTING, h.service.audioRuntimeState.value)
            h.engine.acceptPlayback = true
            h.audioPlane.emitPCM(ByteArray(320))
            awaitCondition("renderer accepted PCM") { h.service.audioRuntimeState.value == AudioRuntimeState.RUNNING }
            awaitCondition("renderer readiness reported") { statuses().last() == com.aessam.toursession.AudioReadinessStatus.PLAYING }
        } finally { h.close() }
    }

    @Test fun guideAuthenticationFailureDoesNotReconnectOrDiscardSelectedRoom() {
        val h = Harness()
        try {
            val room = h.discoverAndJoin()
            h.connectGuest()
            val starts = h.control.startGuestCalls
            h.audioPlane.emit(AudioSessionEvent.AuthenticationFailed("Guide authentication failed"))
            awaitCondition("authentication failed") { h.service.connectionState.value == SessionConnectionState.FAILED }
            h.scheduler.advanceTimeBy(60_000)
            h.scheduler.runCurrent()
            assertEquals(starts, h.control.startGuestCalls)
            assertEquals(room.id, h.service.activeChannelID.value)
        } finally { h.close() }
    }

    @Test fun playbackStartupFailureIsRetryableWithoutClearingRoomOrOtherLanes() {
        val h = Harness()
        try {
            h.engine.startPlaybackError = IllegalStateException("Output device unavailable")
            val room = h.discoverAndJoin()
            h.connectGuest()
            assertEquals(AudioRuntimeState.FAILED, h.service.audioRuntimeState.value)
            assertEquals("Output device unavailable", h.service.audioRuntimeError.value)
            val controlStarts = h.control.startGuestCalls
            val assetStarts = h.asset.startGuestCalls
            val audioStarts = h.audioPlane.startListeningCalls
            h.resetClearSessionBaselines()
            h.engine.startPlaybackError = null
            h.service.retryAudio()
            assertEquals(AudioRuntimeState.STARTING, h.service.audioRuntimeState.value)
            h.audioPlane.emitPCM(ByteArray(320))
            awaitCondition("retry audible") { h.service.audioRuntimeState.value == AudioRuntimeState.RUNNING }
            assertEquals(room.id, h.service.activeChannelID.value)
            assertEquals(controlStarts, h.control.startGuestCalls)
            assertEquals(assetStarts, h.asset.startGuestCalls)
            assertEquals(audioStarts, h.audioPlane.startListeningCalls)
            assertEquals(0, h.control.clearSessionCalls)
            assertEquals(0, h.asset.clearSessionCalls)
            assertTrue(h.uncaught.isEmpty())
        } finally { h.close() }
    }

    @Test fun playbackWriteFailureAndFocusLossStopClaimingLiveAudio() {
        val h = Harness()
        try {
            h.discoverAndJoin()
            h.connectGuest()
            h.audioPlane.emitPCM(ByteArray(320))
            h.engine.playbackFailureHandler?.invoke(-6)
            awaitCondition("playback failure") { h.service.audioRuntimeState.value == AudioRuntimeState.FAILED }
            assertFalse(h.engine.isPlaying)
            h.service.retryAudio()
            h.audioPlane.emitPCM(ByteArray(320))
            awaitCondition("playback retry") { h.service.audioRuntimeState.value == AudioRuntimeState.RUNNING }
            h.engine.onAudioFocusLost?.invoke()
            awaitCondition("focus interruption") { h.service.audioRuntimeState.value == AudioRuntimeState.INTERRUPTED }
            assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
            assertFalse(h.engine.isPlaying)
        } finally { h.close() }
    }

    @Test fun microphoneRestartPreservesRoomAndControlAssetSessions() {
        val h = Harness()
        try {
            val room = h.createGuide()
            h.engine.onAudioFocusLost?.invoke()
            awaitCondition("microphone interruption") { h.service.audioRuntimeState.value == AudioRuntimeState.INTERRUPTED }
            assertFalse(h.engine.isCapturing)
            h.resetClearSessionBaselines()
            h.service.restartMicrophone()
            awaitCondition("microphone restarted") { h.service.audioRuntimeState.value == AudioRuntimeState.RUNNING }
            assertEquals(room.id, h.service.activeChannelID.value)
            assertEquals(2, h.engine.startCaptureCalls)
            assertEquals(1, h.control.startGuideCalls)
            assertEquals(1, h.asset.startGuideCalls)
            assertEquals(1, h.audioPlane.startBroadcastingCalls)
            assertEquals(0, h.control.clearSessionCalls)
            assertEquals(0, h.asset.clearSessionCalls)
        } finally { h.close() }
    }

    @Test fun failedMicrophoneRestartKeepsTourAvailableForAnotherRetry() {
        val h = Harness()
        try {
            val room = h.createGuide()
            h.engine.startCaptureError = IllegalStateException("Microphone unavailable")
            h.service.restartMicrophone()
            awaitCondition("restart failure") { h.service.audioRuntimeState.value == AudioRuntimeState.FAILED }
            assertEquals(room.id, h.service.activeChannelID.value)
            assertEquals(ListenState.BROADCASTING, h.service.listenState.value)
            h.engine.startCaptureError = null
            h.service.restartMicrophone()
            awaitCondition("second microphone restart") { h.service.audioRuntimeState.value == AudioRuntimeState.RUNNING }
            h.service.leaveChannel()
            assertEquals(AudioRuntimeState.IDLE, h.service.audioRuntimeState.value)
        } finally { h.close() }
    }

    @Test fun failedNearbyAdmissionClosesRouteAndPermitsRetry() {
        val h = Harness()
        try {
            val channel = Channel(UUID.randomUUID().toString(), "Nearby", 0.0,
                UUID.randomUUID().toString(), roomAdmissionVersion = 2)
            h.admission.joinError = IllegalStateException("Admission rejected")
            assertFalse(h.service.canJoin(channel))
            h.controlPlane.nearbyAvailable = true
            assertTrue(h.service.canJoin(channel))
            val stops = h.controlPlane.nearbyStopCalls
            h.service.joinChannel(channel, "")
            awaitCondition("failed nearby admission") {
                h.scheduler.runCurrent(); h.service.connectionState.value == SessionConnectionState.FAILED
            }
            assertEquals(stops + 1, h.controlPlane.nearbyStopCalls)
            assertFalse(h.controlPlane.usesBluetoothGuestRoute)
            assertEquals(0, h.control.startGuestCalls)
            h.service.joinChannel(channel, "")
            awaitCondition("second nearby admission") { h.scheduler.runCurrent(); h.controlPlane.nearbyPrepareCalls == 2 }
        } finally { h.close() }
    }
    @Test fun bluetoothDiscoveryLifecycle() {
        val h = Harness()
        try {
            h.service.start()
            awaitCondition("Bluetooth OFF") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.OFF }
            h.service.setBluetoothDiscoveryEnabled(true)
            awaitCondition("Bluetooth BROWSING") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.BROWSING }
            h.service.setDiscoveryForeground(false)
            awaitCondition("Bluetooth OFF") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.OFF }
            h.service.setDiscoveryForeground(true)
            awaitCondition("Bluetooth BROWSING") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.BROWSING }
            h.discoverAndJoin()
            awaitCondition("Bluetooth OFF") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.OFF }
            h.service.leaveChannel()
            awaitCondition("Bluetooth BROWSING") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.BROWSING }
            h.service.setBluetoothDiscoveryEnabled(false)
            awaitCondition("Bluetooth OFF") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.OFF }
        } finally { h.close() }
    }

    @Test fun bluetoothGuideLifecycle() {
        val h = Harness()
        try {
            h.service.start()
            h.createGuide()
            awaitCondition("Bluetooth OFF") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.OFF }
            h.service.setBluetoothDiscoveryEnabled(true)
            awaitCondition("Bluetooth ADVERTISING") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.ADVERTISING }
            h.service.setDiscoveryForeground(false)
            // Locking the guide must not tear down the Bluetooth session listener.
            awaitCondition("Bluetooth ADVERTISING in background") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.ADVERTISING }
            h.service.setDiscoveryForeground(true)
            awaitCondition("Bluetooth ADVERTISING") { h.scheduler.runCurrent(); h.controlPlane.bluetoothMode == com.aessam.comeoverhere.core.BluetoothDiscoveryMode.ADVERTISING }
        } finally { h.close() }
    }

    private class Harness(reconnectBaseDelayMillis: Long = 1L,
        admissionOverride: com.aessam.comeoverhere.core.RoomAdmissionInterface? = null,
        val controlPlane: LifecycleControlPlane = LifecycleControlPlane(),
        coordinatorControlPlane: com.aessam.comeoverhere.core.ControlPlane = controlPlane,
        queuedDispatch: Boolean = false) {
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val scheduler = TestCoroutineScheduler()
        val scope = CoroutineScope(
            SupervisorJob() + (if (queuedDispatch) StandardTestDispatcher(scheduler) else UnconfinedTestDispatcher(scheduler)) +
                CoroutineExceptionHandler { _, error -> uncaught += error },
        )
        val audioPlane = LifecycleAudioPlane()
        val control = LifecycleControlTransport()
        val asset = LifecycleAssetTransport()
        val engine = FakeAudioEngine()
        val admission = LifecycleRoomAdmission()
        val guidance = FakeLocalGuidance()
        private val root = Files.createTempDirectory("GetOverHereLifecycle-").toFile()
        val coordinator = NetworkCoordinator(coordinatorControlPlane, audioPlane, scope)
        val service = ChannelService(
            coordinator,
            engine,
            scope,
            TourControlService(control),
            TourAssetTransferService(asset, FileTourAssetCache(root.resolve("cache"))),
            TourContentStore(root.resolve("packs")),
            guidance,
            reconnectBaseDelayMillis,
            admissionOverride ?: admission,
        )

        fun resetClearSessionBaselines() {
            control.clearSessionCalls = 0
            asset.clearSessionCalls = 0
            audioPlane.clearSessionCalls = 0
        }

        fun close() {
            scope.cancel()
            root.deleteRecursively()
        }
    }

    // MARK: - FND-2

    @Test
    fun createChannelPublishesOnlyAfterCaptureStarts() {
        val h = Harness()
        try {
            h.engine.startCaptureError = SecurityException("Microphone permission is required")
            var broadcastingCallsAtCaptureStart = -1
            h.engine.onStartCapture = { broadcastingCallsAtCaptureStart = h.audioPlane.startBroadcastingCalls }

            h.service.createChannel("Tour")
            awaitCondition("failed guide startup") {
                h.service.connectionState.value == SessionConnectionState.FAILED
            }

            assertEquals(ListenState.IDLE, h.service.listenState.value)
            assertTrue(h.service.channels.value.isEmpty())
            assertNull(h.service.activeChannelID.value)
            assertEquals("Microphone permission is required", h.service.tourFeatureError.value)
            assertTrue("NSD must not advertise a tour that cannot capture", h.controlPlane.announcedChannelIDs.isEmpty())
            assertEquals(1, h.controlPlane.endedChannelIDs.size)
            assertEquals(1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)
            assertEquals("audio lane starts before capture", 1, broadcastingCallsAtCaptureStart)
            assertEquals(1, h.engine.startCaptureCalls)
            assertTrue(h.uncaught.isEmpty())
        } finally {
            h.close()
        }
    }

    @Test
    fun createChannelRollsBackWhenControlLaneFailsToBind() {
        val h = Harness()
        try {
            h.control.startGuideError = IllegalStateException("Session: bind/listen failed: Address already in use")

            h.service.createChannel("Tour")
            awaitCondition("failed guide startup") {
                h.service.connectionState.value == SessionConnectionState.FAILED
            }

            assertEquals(ListenState.IDLE, h.service.listenState.value)
            assertTrue(h.service.channels.value.isEmpty())
            assertTrue(h.service.tourFeatureError.value!!.contains("bind/listen failed"))
            assertTrue(h.controlPlane.announcedChannelIDs.isEmpty())
            assertEquals(1, h.controlPlane.endedChannelIDs.size)
            assertEquals(1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals("no audio plane was selected before the bind failure", 0, h.audioPlane.clearSessionCalls)
            assertEquals(0, h.audioPlane.startBroadcastingCalls)
            assertEquals(0, h.engine.startCaptureCalls)
        } finally {
            h.close()
        }
    }

    // MARK: - FND-6

    @Test
    fun guideAddressChangeReconfiguresWithoutClearingSession() {
        val h = Harness()
        try {
            val channel = h.discoverAndJoin("10.0.0.1")
            h.connectGuest()
            h.resetClearSessionBaselines()

            h.controlPlane.emit(announce(channel, audioHostIP = "10.0.0.2"))
            awaitCondition("guest lanes restarted") { h.control.startGuestCalls == 2 }

            assertEquals(0, h.control.clearSessionCalls)
            assertEquals(0, h.asset.clearSessionCalls)
            assertEquals(0, h.audioPlane.clearSessionCalls)
            assertEquals("10.0.0.2", h.control.startGuestHostIPs.last())
            assertEquals(0, h.service.reconnectAttempt.value)
            assertEquals(SessionConnectionState.CONNECTING, h.service.connectionState.value)
        } finally {
            h.close()
        }
    }

    // MARK: - FND-8

    @Test fun bluetoothObservationPreservesActiveSession() {
        val h = Harness()
        try {
            val channel = h.discoverAndJoin()
            h.connectGuest()
            h.resetClearSessionBaselines()
            h.controlPlane.emit(announce(channel, "10.0.0.1").copy(channelName = "Bluetooth room", audioHostIP = null))
            awaitCondition("Bluetooth metadata applied") { h.service.channels.value.first().name == "Bluetooth room" }
            assertEquals(1, h.control.startGuestCalls)
            assertEquals(0, h.control.clearSessionCalls)
            assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
        } finally { h.close() }
    }

    @Test
    fun endTourFlushesLeaveOffMainAndClearsAfterDelivery() {
        val h = Harness()
        try {
            val channel = h.createGuide()
            h.control.leaveGate = CompletableDeferred()

            h.service.leaveChannel()

            assertEquals(ListenState.IDLE, h.service.listenState.value)
            assertNull(h.service.activeChannelID.value)
            assertEquals(channel.id, h.controlPlane.endedChannelIDs.last())
            assertFalse("End Tour must not use the blocking leave path", h.control.blockingLeaveUsed)
            assertEquals(1, h.control.leaveFlushCount)
            assertEquals("lanes stay until the leave is delivered", 0, h.control.clearSessionCalls)
            assertEquals(0, h.asset.clearSessionCalls)
            assertEquals(0, h.audioPlane.clearSessionCalls)

            h.control.leaveGate!!.complete(Unit)

            assertEquals(1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)
            assertTrue(h.uncaught.isEmpty())
        } finally {
            h.close()
        }
    }

    /**
     * A second End Tour with no active channel inside the flush window must not disown the pending
     * teardown: the lanes still hold the ended tour's credential (ADR-048).
     */
    @Test
    fun endTourTeardownSurvivesANoOpLeave() {
        val h = Harness()
        try {
            h.createGuide()
            h.control.leaveGate = CompletableDeferred()

            h.service.leaveChannel()
            assertEquals(1, h.control.leaveFlushCount)
            assertNull(h.service.activeChannelID.value)

            h.service.leaveChannel()

            assertEquals("no-op leaves must not flush again", 1, h.control.leaveFlushCount)
            assertEquals("lanes stay until the leave is delivered", 0, h.control.clearSessionCalls)

            h.control.leaveGate!!.complete(Unit)

            assertEquals("lanes cleared after delivery despite the no-op leave", 1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)
            assertTrue(h.uncaught.isEmpty())
        } finally {
            h.close()
        }
    }

    /**
     * A Create started inside the flush window whose credential stretch outlives the flush must
     * survive the deferred teardown: the teardown belongs to the leave that already invalidated
     * older stretches and must not discard the user's newest action (ADR-048).
     */
    @Test
    fun endTourTeardownDoesNotDiscardAFollowingCreate() {
        val h = Harness()
        try {
            h.createGuide()
            h.control.leaveGate = CompletableDeferred()

            h.service.leaveChannel()
            assertEquals(1, h.control.leaveFlushCount)

            h.service.createChannel("Tour 2")
            h.control.leaveGate!!.complete(Unit)

            awaitCondition("second tour broadcasting after the deferred teardown") {
                h.service.listenState.value == ListenState.BROADCASTING
            }
            assertEquals("Tour 2", h.service.activeChannel?.name)
            assertEquals("the ended tour's lanes were still cleared", 1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)
            assertTrue(h.uncaught.isEmpty())
        } finally {
            h.close()
        }
    }

    @Test
    fun versionMismatchErasesTransportCredentials() {
        val h = Harness()
        try {
            h.discoverAndJoin()
            h.connectGuest()
            h.resetClearSessionBaselines()

            h.control.emit(SessionControlEvent.VersionMismatch(3, 4))

            assertEquals(SessionConnectionState.FAILED, h.service.connectionState.value)
            assertTrue(h.service.tourFeatureError.value!!.contains("version mismatch"))
            assertEquals(1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)

            h.control.emit(SessionControlEvent.Disconnected)
            h.scheduler.advanceTimeBy(1_000)
            h.scheduler.runCurrent()
            assertEquals(SessionConnectionState.FAILED, h.service.connectionState.value)
            assertEquals(1, h.control.startGuestCalls)
        } finally {
            h.close()
        }
    }

    @Test
    fun credentialRejectionIsTerminal() {
        val h = Harness()
        try {
            h.discoverAndJoin()
            h.resetClearSessionBaselines()

            h.control.emit(SessionControlEvent.CredentialRejected("Session: the tour code was rejected by the guide"))

            assertEquals(SessionConnectionState.FAILED, h.service.connectionState.value)
            assertTrue(h.service.tourFeatureError.value!!.contains("tour code"))
            assertEquals(1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)

            h.scheduler.advanceTimeBy(1_000)
            h.scheduler.runCurrent()
            assertEquals("a rejected code is never retried", 1, h.control.startGuestCalls)
            assertEquals(0, h.service.reconnectAttempt.value)
        } finally {
            h.close()
        }
    }

    @Test
    fun reconnectExhaustionErasesTransportCredentials() {
        val h = Harness(reconnectBaseDelayMillis = 1L)
        try {
            h.discoverAndJoin()
            h.connectGuest()
            h.resetClearSessionBaselines()

            h.control.emit(SessionControlEvent.Disconnected)
            assertEquals(SessionConnectionState.RECONNECTING, h.service.connectionState.value)
            for (attempt in 1..5) {
                h.scheduler.advanceTimeBy(1L shl (attempt - 1))
                h.scheduler.runCurrent()
                assertEquals("reconnect $attempt restarts the lanes", attempt + 1, h.control.startGuestCalls)
                h.control.emit(SessionControlEvent.Failed("connect failed"))
            }

            assertEquals(SessionConnectionState.FAILED, h.service.connectionState.value)
            assertEquals("Could not reconnect to the guide", h.service.tourFeatureError.value)
            assertEquals(1, h.control.clearSessionCalls)
            assertEquals(1, h.asset.clearSessionCalls)
            assertEquals(1, h.audioPlane.clearSessionCalls)
            assertEquals(6, h.control.startGuestCalls)

            h.scheduler.advanceTimeBy(10_000)
            h.scheduler.runCurrent()
            assertEquals(6, h.control.startGuestCalls)
        } finally {
            h.close()
        }
    }

    // MARK: - FND-13

    @Test
    fun connectedAndAudioReadyCountsAreIndependent() {
        val h = Harness()
        try {
            h.createGuide()
            val guest = ParticipantSession(UUID.randomUUID(), "a-1", "A", SessionRole.GUEST, ParticipantPlatform.IOS)

            h.control.emit(SessionControlEvent.GuestJoined(guest))
            assertEquals(1, h.service.connectedGuestCount.value)
            assertEquals(0, h.service.listenerCount.value)

            h.audioPlane.emit(AudioSessionEvent.Joined(guest))
            assertEquals(1, h.service.listenerCount.value)

            // Re-registration arrives as disconnect + join and counts once.
            h.control.emit(SessionControlEvent.GuestDisconnected(guest.participantId))
            h.control.emit(SessionControlEvent.GuestJoined(guest))
            assertEquals(1, h.service.connectedGuestCount.value)

            h.control.emit(SessionControlEvent.GuestDisconnected(guest.participantId))
            assertEquals(0, h.service.connectedGuestCount.value)
            assertEquals(1, h.service.listenerCount.value)
        } finally {
            h.close()
        }
    }

    @Test
    fun speakerOutputExposesFeedbackWarning() {
        val h = Harness()
        try {
            h.discoverAndJoin()
            assertNull(h.service.speakerFeedbackWarning.value)

            h.service.setListenerOutput(ListenerOutput.SPEAKER)
            awaitCondition("warning shown") { h.service.speakerFeedbackWarning.value != null }
            assertEquals(ChannelService.SPEAKER_FEEDBACK_WARNING, h.service.speakerFeedbackWarning.value)

            h.service.setListenerOutput(ListenerOutput.PRIVATE_AUDIO)
            awaitCondition("warning hidden") { h.service.speakerFeedbackWarning.value == null }

            h.service.leaveChannel()
            h.service.setListenerOutput(ListenerOutput.SPEAKER)
            assertNull("not listening", h.service.speakerFeedbackWarning.value)
        } finally {
            h.close()
        }
    }

    @Test
    fun forcedPrivateOutputCallbackUpdatesListenerOutput() {
        val h = Harness()
        try {
            h.discoverAndJoin()
            h.service.setListenerOutput(ListenerOutput.SPEAKER)
            assertEquals(ListenerOutput.SPEAKER, h.service.listenerOutput.value)

            val forcedPrivate = h.engine.onOutputForcedPrivate
            assertNotNull("ChannelService must install the forced-private callback", forcedPrivate)
            forcedPrivate!!.invoke()

            assertEquals(ListenerOutput.PRIVATE_AUDIO, h.service.listenerOutput.value)
        } finally {
            h.close()
        }
    }

    @Test
    fun captureStreamEndSurfacesError() {
        val h = Harness()
        try {
            val failSignal = CompletableDeferred<Unit>()
            h.engine.captureFlow = flow {
                emit(ByteArray(4))
                failSignal.await()
                throw IllegalStateException("microphone died")
            }
            h.createGuide()
            // The capture collector is a launch nested in the credential-hop coroutine; on an
            // unconfined dispatcher it runs after the outer body completes, so poll for the frame.
            awaitCondition("first captured frame forwarded") { h.audioPlane.sent.size == 1 }
            assertNull(h.service.tourFeatureError.value)

            failSignal.complete(Unit)

            awaitCondition("capture error surfaced") {
                h.service.audioRuntimeError.value == "Microphone capture stopped"
            }
            assertEquals("control and asset lanes stay up (DSCN-12)", ListenState.BROADCASTING, h.service.listenState.value)
            assertTrue(h.uncaught.isEmpty())
        } finally {
            h.close()
        }
    }

    // MARK: - G5 FND-9

    /** Passes before G5 on Android (ChannelService.kt already stored `event.message`); pins parity with iOS. */
    @Test
    fun assetTransferFailureSurfacesInTourFeatureError() {
        val h = Harness()
        try {
            assertNull(h.service.tourFeatureError.value)

            h.asset.emit(SessionAssetEvent.Failed("Asset lane failed"))

            awaitCondition("asset failure surfaced", timeoutMillis = 2_000) {
                h.service.tourFeatureError.value == "Asset lane failed"
            }
            assertTrue(h.uncaught.isEmpty())
        } finally {
            h.close()
        }
    }

    @Test fun roomSettingsPreserveExistingConnections() {
        val h = Harness()
        try {
            h.createGuide()
            assertEquals(false, h.service.isRoomLocked.value)
            assertEquals("", h.service.tourCode.value)
            val controlConfigurations = h.control.configureCalls
            val audioConfigurations = h.audioPlane.configureCalls
            val assetConfigurations = h.asset.configureCalls
            listOf(true to "1234", true to "Edited!", false to "Edited!").forEach { (locked, code) ->
                h.service.updateRoomAccess(locked, code)
                awaitCondition("room update") { !h.service.isUpdatingRoomAccess.value }
                assertEquals(null, h.service.roomAccessError.value)
                assertEquals(locked, h.service.isRoomLocked.value)
                assertEquals(code, h.service.tourCode.value)
                assertEquals(SessionConnectionState.CONNECTED, h.service.connectionState.value)
                assertEquals(controlConfigurations, h.control.configureCalls)
                assertEquals(audioConfigurations, h.audioPlane.configureCalls)
                assertEquals(assetConfigurations, h.asset.configureCalls)
            }
        } finally { h.close() }
    }

    // MARK: - Helpers

    private class RouteAdmission : com.aessam.comeoverhere.core.RoomAdmissionInterface by LifecycleRoomAdmission() {
        data class Call(val host: String, val room: UUID, val guide: UUID, val code: String?)
        val calls = CopyOnWriteArrayList<Call>()
        private val actual = LifecycleRoomAdmission()
        var unreachableLAN = false
        var unreachableNearby = false
        var terminalError: Exception? = null
        var beforeJoin: ((String) -> Unit)? = null
        @Volatile var returned = false
        override fun join(host: String, sessionID: UUID, expectedGuideID: UUID, code: String?): com.aessam.toursession.AdmittedRoomCredentials {
            calls += Call(host, sessionID, expectedGuideID, code)
            try {
                beforeJoin?.invoke(host)
                terminalError?.let { throw it }
                if (if (host == "127.0.0.1") unreachableNearby else unreachableLAN) throw com.aessam.comeoverhere.core.RoomAdmissionTransportError(
                    java.net.ConnectException("LAN unreachable"))
                return actual.join(host, sessionID, expectedGuideID, code)
            } finally { returned = true }
        }
    }

    private fun Harness.createGuide(): Channel {
        service.createChannel("Tour")
        awaitCondition("broadcasting") { service.listenState.value == ListenState.BROADCASTING }
        val channel = service.activeChannel
        assertNotNull("guide channel must be active after startup", channel)
        return channel!!
    }

    /** Discovery must append the channel first: `scheduleReconnect` and the IP-change path resolve through `channels`. */
    private fun Harness.discoverAndJoin(hostIP: String? = "10.0.0.1"): Channel {
        service.start()
        val channelID = UUID.randomUUID().toString()
        controlPlane.emit(
            BLECommand.ChannelAnnounce(
                channelID = channelID,
                channelName = "Tour",
                createdBy = UUID.randomUUID().toString(),
                audioQuality = AudioQuality.STANDARD,
                wifiSSID = null,
                audioHostIP = hostIP,
                roomAdmissionVersion = 2,
            ),
        )
        awaitCondition("discovered channel") { service.channels.value.any { it.id == channelID } }
        val channel = service.channels.value.first { it.id == channelID }
        val controlStarts = control.startGuestCalls
        val audioStarts = audioPlane.startListeningCalls
        service.joinChannel(channel, TOUR_CODE)
        awaitCondition("guest transports started") {
            service.connectionState.value == SessionConnectionState.CONNECTING &&
                control.startGuestCalls > controlStarts &&
                audioPlane.startListeningCalls > audioStarts
        }
        return channel
    }

    private fun Harness.connectGuest() {
        control.emit(SessionControlEvent.Connected)
        awaitCondition("connected") { service.connectionState.value == SessionConnectionState.CONNECTED }
    }

    private fun announce(channel: Channel, audioHostIP: String?) = BLECommand.ChannelAnnounce(
        channelID = channel.id,
        channelName = channel.name,
        createdBy = channel.createdBy,
        audioQuality = AudioQuality.STANDARD,
        wifiSSID = null,
        audioHostIP = audioHostIP,
        roomAdmissionVersion = 2,
    )

    private fun awaitCondition(description: String, timeoutMillis: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) throw AssertionError("Timed out waiting for $description")
            Thread.sleep(5)
        }
    }

    private companion object {
        const val TOUR_CODE = "23456789AB"
    }
}
