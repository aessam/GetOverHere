package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.SessionAssetEvent
import com.aessam.comeoverhere.core.SessionGuideAuthentication
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.toursession.AssetChunkPayload
import com.aessam.toursession.AssetRequestPayload
import com.aessam.toursession.GuideAssetSchedule
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import com.aessam.toursession.SessionRole
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class GuideAssetSchedulingServiceTest {
    @Test(timeout = 10_000) fun stoppedRunCannotSendAChunkWhoseFileReadWasAlreadyStarted() = checkReadCancellation(0)
    @Test(timeout = 10_000) fun disconnectedMemberCannotReceiveAChunkWhoseFileReadWasAlreadyStarted() = checkReadCancellation(1)
    @Test(timeout = 10_000) fun replacedMemberCannotReceiveAnOldConnectionsPendingFileRead() = checkReadCancellation(2)
    @Test(timeout = 10_000) fun slowDiskCannotCreateAnUnboundedGuideEventInbox() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val f = Fixture { _, _, count ->
            entered.countDown(); check(release.await(4, TimeUnit.SECONDS)); ByteArray(count)
        }
        try {
            f.join(); f.request(0)
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            repeat(200) { f.request(61_440) }
            assertEquals(90, f.service.pendingGuideEventCount)
            assertTrue(f.service.lastError?.contains("backlog is full") == true)
            f.service.stop()
            release.countDown()
            f.awaitCondition { f.service.pendingGuideEventCount == 0 }
            assertTrue(f.chunks().isEmpty())
        } finally { release.countDown(); f.close() }
    }

    private fun checkReadCancellation(action: Int) {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val f = Fixture { _, _, count ->
            entered.countDown(); check(release.await(4, TimeUnit.SECONDS)); ByteArray(count).also { finished.countDown() }
        }
        try {
            f.join()
            f.request(0)
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            when (action) {
                0 -> f.service.stop()
                1 -> f.transport.emit(SessionAssetEvent.GuestDisconnected(f.member))
                2 -> f.announceJoined(f.member)
            }
            release.countDown()
            assertTrue(finished.await(3, TimeUnit.SECONDS))
            // A later event on the same worker is the barrier proving the stale send has finished.
            val marker = UUID.randomUUID()
            if (action == 0) f.start()
            f.join(marker)
            f.awaitCondition { f.service.connectedParticipantIDs.contains(marker) }
            assertTrue("Stale file read sent data after teardown", f.chunks().isEmpty())
        } finally { release.countDown(); f.close() }
    }

    @Test(timeout = 10_000) fun guidePayloadPacingAndPerMemberQueueAreBounded() {
        val f = Fixture()
        try {
            f.join()
            f.request(0)
            f.awaitCondition { f.chunks().size == 1 }
            f.request(61_440)
            f.request(122_880)
            f.request(184_320)
            f.awaitCondition { f.service.lastError?.contains("MEMBER_QUEUE_FULL") == true }
            assertEquals("Only one 60KiB burst is immediately available", 1, f.chunks().size)
            f.awaitCondition { f.chunks().size == 3 }
            assertEquals(listOf(0L, 61_440L, 122_880L), f.chunks().map { it.offset })
            assertTrue(f.chunks().all { it.bytes.size <= 61_440 })
        } finally { f.close() }
    }

    private class Fixture(read: ((File, Long, Int) -> ByteArray)? = null) {
        private val root = Files.createTempDirectory("GetOverHereGuideSchedule-").toFile()
        private val source = root.resolve("slide.bin").apply { writeBytes(ByteArray(245_760) { (it % 251).toByte() }) }
        private val hash = MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") { "%02x".format(it) }
        private val descriptor = TourAssetDescriptor("slide", TourAssetKind.SLIDE, hash, source.length(), 0, "image/jpeg")
        private val manifest = TourPackManifestPayload(UUID.randomUUID(), 1, "Tour", listOf(descriptor))
        private val room = UUID.randomUUID()
        private val guide = UUID.randomUUID()
        private val credential = SessionCredential.derive("23456789AB", room)
        val member: UUID = UUID.randomUUID()
        val transport = LifecycleAssetTransport()
        val service = if (read == null) TourAssetTransferService(transport, FileTourAssetCache(root.resolve("cache")),
            guideSchedule = GuideAssetSchedule(bytesPerSecond = 61_440))
        else TourAssetTransferService(transport, FileTourAssetCache(root.resolve("cache")), readSource = read)
        init { start() }
        fun start() {
            service.configureGuideAuthentication(SessionGuideAuthentication.LegacyFixture)
            service.configureSession(room, guide, "Guide", ParticipantPlatform.ANDROID, credential)
            service.hostTourPack(manifest, mapOf("slide" to source))
        }
        fun join(id: UUID = member) {
            announceJoined(id)
            awaitCondition { service.connectedParticipantIDs.contains(id) }
        }
        fun announceJoined(id: UUID) {
            transport.emit(SessionAssetEvent.GuestJoined(ParticipantSession(id, UUID.randomUUID().toString(), "Guest",
                SessionRole.GUEST, ParticipantPlatform.ANDROID)))
        }
        fun request(offset: Long) = transport.emit(SessionAssetEvent.EnvelopeReceived(SessionEnvelope(
            lane = SessionLane.ASSET, kind = SessionMessageKind.ASSET_REQUEST, sequence = offset,
            sessionId = room, senderId = member, payload = AssetRequestPayload(hash, offset).encode())))
        fun chunks() = transport.sent.filter { it.kind == SessionMessageKind.ASSET_CHUNK }.map { AssetChunkPayload.decode(it.payload) }
        fun close() { service.stop(); root.deleteRecursively() }
        fun awaitCondition(condition: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
            while (!condition()) {
                check(System.nanoTime() < deadline) { "Asset scheduling condition timed out" }
                java.util.concurrent.locks.LockSupport.parkNanos(1_000_000)
            }
        }
    }
}
