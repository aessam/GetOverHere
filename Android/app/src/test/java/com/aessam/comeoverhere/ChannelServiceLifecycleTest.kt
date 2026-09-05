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
    private class Harness(reconnectBaseDelayMillis: Long = 1L) {
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val scheduler = TestCoroutineScheduler()
        val scope = CoroutineScope(
            SupervisorJob() + UnconfinedTestDispatcher(scheduler) +
                CoroutineExceptionHandler { _, error -> uncaught += error },
        )
        val controlPlane = LifecycleControlPlane()
        val audioPlane = LifecycleAudioPlane()
        val control = LifecycleControlTransport()
        val asset = LifecycleAssetTransport()
        val engine = FakeAudioEngine()
        val guidance = FakeLocalGuidance()
        private val root = Files.createTempDirectory("GetOverHereLifecycle-").toFile()
        val coordinator = NetworkCoordinator(controlPlane, audioPlane, scope)
        val service = ChannelService(
            coordinator,
            engine,
            scope,
            TourControlService(control),
            TourAssetTransferService(asset, FileTourAssetCache(root.resolve("cache"))),
            TourContentStore(root.resolve("packs")),
            guidance,
            reconnectBaseDelayMillis,
            LifecycleRoomAdmission(),
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
                h.service.tourFeatureError.value == "Microphone capture stopped"
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

    private fun Harness.createGuide(): Channel {
        service.createChannel("Tour")
        awaitCondition("broadcasting") { service.listenState.value == ListenState.BROADCASTING }
        val channel = service.activeChannel
        assertNotNull("guide channel must be active after startup", channel)
        return channel!!
    }

    /** Discovery must append the channel first: `scheduleReconnect` and the IP-change path resolve through `channels`. */
    private fun Harness.discoverAndJoin(hostIP: String = "10.0.0.1"): Channel {
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
            ),
        )
        awaitCondition("discovered channel") { service.channels.value.any { it.id == channelID } }
        val channel = service.channels.value.first { it.id == channelID }
        service.joinChannel(channel, TOUR_CODE)
        awaitCondition("guest transports started") {
            service.connectionState.value == SessionConnectionState.CONNECTING &&
                control.startGuestCalls >= 1 &&
                audioPlane.startListeningCalls >= 1
        }
        return channel
    }

    private fun Harness.connectGuest() {
        control.emit(SessionControlEvent.Connected)
        awaitCondition("connected") { service.connectionState.value == SessionConnectionState.CONNECTED }
    }

    private fun announce(channel: Channel, audioHostIP: String) = BLECommand.ChannelAnnounce(
        channelID = channel.id,
        channelName = channel.name,
        createdBy = channel.createdBy,
        audioQuality = AudioQuality.STANDARD,
        wifiSSID = null,
        audioHostIP = audioHostIP,
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
