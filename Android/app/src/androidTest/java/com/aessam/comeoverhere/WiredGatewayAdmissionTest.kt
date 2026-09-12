package com.aessam.comeoverhere

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.RoomAdmissionTransport
import com.aessam.comeoverhere.core.WiredCompanionTransport
import com.aessam.comeoverhere.core.WiredInterfaceAddress
import com.aessam.comeoverhere.core.HubIdentity
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.GatewayLane
import com.aessam.toursession.GatewayLaneRequest
import com.aessam.toursession.GatewayRoomDescriptor
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.RoomAdmissionV2
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.DataInputStream
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.InetSocketAddress
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.ssl.SSLSocket

/** Full native TLS + production guide admission + fixed-lane proxy. Loopback is not USB proof. */
@RunWith(AndroidJUnit4::class)
class WiredGatewayAdmissionTest {
    @Test fun twoIndependentGuestsAdmitThroughOneCompanionAndFifthPendingAdmissionIsRejected() {
        val aliases = List(2) { "goh.gateway.test.${UUID.randomUUID()}" }
        val guide = WiredCompanionTransport(aliases[0], enableAddressRecovery = false)
        val companion = WiredCompanionTransport(aliases[1], enableAddressRecovery = false)
        val admission = RoomAdmissionTransport()
        val room = UUID.randomUUID(); val guideID = UUID.randomUUID(); val signer = GuideFrameSigner(room, guideID)
        val record = BluetoothRoomRecord(room, guideID, "Native gateway admission fixture", true, false, 2)
        val descriptor = GatewayRoomDescriptor(1, 1, record, signer.publicKey)
        val local = InetAddress.getByName("127.0.0.1")
        val address = WiredInterfaceAddress(NetworkInterface.getByInetAddress(local).name, local, 8)
        val connected = CountDownLatch(1)
        val errors = CopyOnWriteArrayList<String>()
        guide.onError = { errors += it }
        val pending = mutableListOf<NearbyByteConnection>()
        val workers = Executors.newFixedThreadPool(2)
        try {
            admission.start(room, "23456789AB", signer)
            val offer = guide.makeOffer(record, signer.publicKey, address) { descriptor }
            val response = companion.answerOffer(offer, address)
            guide.confirmResponse(response)
            companion.onDescriptor = { if (it != null) connected.countDown() }
            companion.startCompanion()
            assertTrue("Native companion handshake/descriptor failed", connected.await(8, TimeUnit.SECONDS))
            fun requestStatus(request: GatewayLaneRequest): Int =
                (HubIdentity(aliases[1]).context(offer.certificateFingerprint).socketFactory.createSocket() as SSLSocket).use { socket ->
                    socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = 3_000
                    socket.connect(InetSocketAddress(local, offer.port), 3_000); socket.startHandshake()
                    socket.outputStream.write(request.encode()); socket.outputStream.flush(); socket.inputStream.read()
                }
            assertEquals(2, requestStatus(GatewayLaneRequest(offer.pairingID, room, 0, GatewayLane.HUB_CONTROL)))
            assertEquals(1, requestStatus(GatewayLaneRequest(offer.pairingID, UUID.randomUUID(), 1, GatewayLane.ADMISSION)))
            val joins = List(2) { workers.submit<String> {
                companion.connect(GatewayLane.ADMISSION).use { link ->
                    val input = DataInputStream(link.input)
                    val challenge = ByteArray(RoomAdmissionV2.CHALLENGE_SIZE).also(input::readFully)
                    val guest = RoomAdmissionV2.Guest(challenge, room, guideID, null)
                    link.output.write(guest.request); link.output.flush()
                    val admitted = guest.open(ByteArray(RoomAdmissionV2.REPLY_SIZE).also(input::readFully))
                    assertArrayEquals(signer.publicKey, admitted.guideIdentity.publicKey)
                    admitted.mediaSecret
                }
            } }
            joins.forEach { assertEquals("23456789AB", it.get(8, TimeUnit.SECONDS)) }
            // Admission reply draining may still hold a slot until its guest's close reaches guide.
            val releaseDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (pending.size < 4) {
                try { pending += companion.connect(GatewayLane.ADMISSION) }
                catch (error: IllegalStateException) {
                    if (System.nanoTime() >= releaseDeadline) throw error
                    java.util.concurrent.locks.LockSupport.parkNanos(20_000_000)
                }
            }
            assertThrows(IllegalStateException::class.java) { companion.connect(GatewayLane.ADMISSION) }
            assertTrue("Admission leaf closure must not break hub control", guide.isConnected)
            assertTrue("Leaf/capacity events must not become association errors: $errors", errors.isEmpty())
        } finally {
            pending.forEach { it.close() }; companion.close(); guide.close(); admission.stop(); workers.shutdownNow()
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); aliases.forEach(::deleteEntry) }
        }
    }
}
