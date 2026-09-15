package com.aessam.comeoverhere

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.core.WiredCompanionTransport
import com.aessam.comeoverhere.core.WiredHubDiscovery
import com.aessam.comeoverhere.core.WiredHubDiscoveryInterface
import com.aessam.comeoverhere.core.WiredInterfaceAddress
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.GatewayRoomDescriptor
import com.aessam.toursession.GuideFrameSigner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.DatagramPacket
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicLong
import javax.jmdns.JmDNS
import javax.jmdns.ServiceEvent
import javax.jmdns.ServiceInfo
import javax.jmdns.ServiceListener

/** Emulator software components; injected link loss is not cable/physical address-change evidence. */
@RunWith(AndroidJUnit4::class)
class WiredRecoveryNativeTest {
    @Test fun failedAcceptLoopRelistensOnUnchangedInterface() {
        val aliases = List(2) { "goh.accept-recovery.test.${UUID.randomUUID()}" }
        val local = InetAddress.getByName("127.0.0.1")
        val address = WiredInterfaceAddress(NetworkInterface.getByInetAddress(local).name, local, 8)
        val injected = java.util.concurrent.atomic.AtomicBoolean(false)
        val failure = CountDownLatch(1); val connected = CountDownLatch(1)
        val guide = WiredCompanionTransport(aliases[0], discovery = ControlledDiscovery(), availableInterfaces = { listOf(address) },
            beforeAccept = { if (injected.compareAndSet(false, true)) throw java.io.IOException("Injected accept failure") })
        val companion = WiredCompanionTransport(aliases[1], discovery = ControlledDiscovery(), availableInterfaces = { listOf(address) })
        val room = UUID.randomUUID(); val guideID = UUID.randomUUID(); val signer = GuideFrameSigner(room, guideID)
        val record = BluetoothRoomRecord(room, guideID, "Accept recovery fixture", true, false, 2)
        try {
            guide.onError = { if (it.contains("Injected accept failure")) failure.countDown() }
            val offer = guide.makeOffer(record, signer.publicKey, address) { GatewayRoomDescriptor(1, 1, record, signer.publicKey) }
            guide.confirmResponse(companion.answerOffer(offer, address))
            assertTrue(failure.await(5, TimeUnit.SECONDS))
            companion.onDescriptor = { if (it != null) connected.countDown() }
            companion.startCompanion()
            assertTrue("Dead listener was not recreated on the same interface", connected.await(12, TimeUnit.SECONDS))
            assertTrue(companion.isConnected && guide.isConnected)
        } finally {
            companion.close(); guide.close()
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); aliases.forEach(::deleteEntry) }
        }
    }

    @Test fun explicitEmulatorEthernetMulticastSocketLoopsBackExactPayload() {
        val nic = requireNotNull(NetworkInterface.getByName("eth0")) { "This software fixture requires the test emulator eth0" }
        val local = requireNotNull(nic.interfaceAddresses.firstOrNull { it.address.address.size == 4 }).address
        val group = InetAddress.getByName("224.0.0.251")
        val payload = UUID.randomUUID().toString().toByteArray(Charsets.US_ASCII)
        MulticastSocket(null).use { receiver ->
            receiver.reuseAddress = true
            receiver.bind(InetSocketAddress(0))
            receiver.networkInterface = nic
            receiver.joinGroup(InetSocketAddress(group, receiver.localPort), nic)
            receiver.soTimeout = 2_000
            MulticastSocket(null).use { sender ->
                sender.bind(InetSocketAddress(local, 0))
                sender.networkInterface = nic
                @Suppress("DEPRECATION")
                val loopbackDisabled = sender.loopbackMode
                android.util.Log.i("WiredRecoveryNativeTest", "multicast interface=${nic.name} source=$local supports=${nic.supportsMulticast()} loopbackDisabled=$loopbackDisabled")
                assertFalse("Public MulticastSocket default unexpectedly disables local delivery", loopbackDisabled)
                sender.send(DatagramPacket(payload, payload.size, group, receiver.localPort))
                val packet = DatagramPacket(ByteArray(256), 256)
                receiver.receive(packet)
                assertEquals(local, packet.address)
                org.junit.Assert.assertArrayEquals(payload, packet.data.copyOf(packet.length))
            }
        }
    }

    @Test fun stoppedNativeAssociationCannotPublishDescriptorReadBeforeStop() {
        val aliases = List(2) { "goh.late-descriptor.test.${UUID.randomUUID()}" }
        val local = InetAddress.getByName("127.0.0.1")
        val address = WiredInterfaceAddress(NetworkInterface.getByInetAddress(local).name, local, 8)
        val beforeCommit = CountDownLatch(1); val releaseCommit = CountDownLatch(1); val published = CountDownLatch(1)
        val guide = WiredCompanionTransport(aliases[0], enableAddressRecovery = false)
        val companion = WiredCompanionTransport(aliases[1], enableAddressRecovery = false, beforeDescriptorCommit = {
            beforeCommit.countDown(); check(releaseCommit.await(5, TimeUnit.SECONDS))
        })
        val room = UUID.randomUUID(); val guideID = UUID.randomUUID(); val signer = GuideFrameSigner(room, guideID)
        val record = BluetoothRoomRecord(room, guideID, "Stale descriptor", true, false, 2)
        try {
            val offer = guide.makeOffer(record, signer.publicKey, address) { GatewayRoomDescriptor(1, 1, record, signer.publicKey) }
            guide.confirmResponse(companion.answerOffer(offer, address))
            companion.onDescriptor = { if (it != null) published.countDown() }
            companion.onConnected = { if (it) published.countDown() }
            companion.startCompanion()
            assertTrue(beforeCommit.await(5, TimeUnit.SECONDS))
            companion.stop(); releaseCommit.countDown()
            assertFalse("A stopped native association published stale guide state", published.await(1, TimeUnit.SECONDS))
            assertFalse(companion.isConnected)
        } finally {
            releaseCommit.countDown(); companion.close(); guide.close()
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); aliases.forEach(::deleteEntry) }
        }
    }

    @Test fun confirmedNativeTLSAssociationRecoversChangedAddressAfterEnrollmentExpiryWithoutNewQR() {
        val aliases = List(2) { "goh.recovery.test.${UUID.randomUUID()}" }
        val local = InetAddress.getByName("127.0.0.1")
        val address = WiredInterfaceAddress(NetworkInterface.getByInetAddress(local).name, local, 8)
        val clock = AtomicLong(System.currentTimeMillis())
        val available = AtomicReference(listOf(address))
        val interfaces = available::get
        val guide = WiredCompanionTransport(aliases[0], discovery = ControlledDiscovery(), availableInterfaces = interfaces, clock = clock::get)
        val companion = WiredCompanionTransport(aliases[1], discovery = ControlledDiscovery(), availableInterfaces = interfaces, clock = clock::get)
        val room = UUID.randomUUID(); val guideID = UUID.randomUUID(); val signer = GuideFrameSigner(room, guideID)
        val record = BluetoothRoomRecord(room, guideID, "Native recovery", true, false, 2)
        val first = CountDownLatch(1); val guideReady = CountDownLatch(1); val lost = CountDownLatch(1); val recovered = CountDownLatch(1)
        val firstGeneration = AtomicLong(); val nextGeneration = AtomicLong()
        try {
            val offer = guide.makeOffer(record, signer.publicKey, address) { GatewayRoomDescriptor(1, 1, record, signer.publicKey) }
            guide.onConnected = { if (it) guideReady.countDown() }
            guide.confirmResponse(companion.answerOffer(offer, address))
            companion.onDescriptor = { value ->
                if (value == null) { if (firstGeneration.get() != 0L) lost.countDown() }
                else if (firstGeneration.compareAndSet(0, value.generation)) first.countDown()
                else if (value.generation != firstGeneration.get()) { nextGeneration.set(value.generation); recovered.countDown() }
            }
            companion.startCompanion()
            assertTrue(first.await(8, TimeUnit.SECONDS))
            assertTrue(guideReady.await(3, TimeUnit.SECONDS))
            clock.addAndGet(180_000)
            available.set(emptyList())
            assertTrue(lost.await(8, TimeUnit.SECONDS))
            available.set(listOf(WiredInterfaceAddress(address.interfaceName, InetAddress.getByName("::1"), 128)))
            assertTrue("Confirmed pair did not reconnect without a new QR", recovered.await(12, TimeUnit.SECONDS))
            assertNotEquals(firstGeneration.get(), nextGeneration.get())
            assertTrue(guide.isConnected && companion.isConnected)
        } finally {
            companion.close(); guide.close()
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); aliases.forEach(::deleteEntry) }
        }
    }

    @Test fun publicJmDNSAdvertisesOnlyExplicitEmulatorEthernetAddressAndCloses() {
        val nic = requireNotNull(NetworkInterface.getByName("eth0")) { "This software fixture requires the test emulator eth0" }
        val entry = requireNotNull(nic.interfaceAddresses.firstOrNull { it.address.address.size == 4 })
        val local = WiredInterfaceAddress(nic.name, entry.address, entry.networkPrefixLength)
        val pairingID = UUID.randomUUID()
        val ready = CountDownLatch(1); val closed = CountDownLatch(1)
        val errors = java.util.concurrent.CopyOnWriteArrayList<String>()
        val advertiser = WiredHubDiscovery().apply {
            onReady = { if (it == null) closed.countDown() else { assertEquals(local, it); ready.countDown() } }
            onError = { errors += it }
        }
        // Independent public JmDNS browser on exactly that interface, not default NSD.
        val host = "goh-test-browser-${UUID.randomUUID()}"
        val browser = JmDNS.create(InetAddress.getByAddress(host, local.address.address), host)
        val resolved = CountDownLatch(1)
        val discovered = AtomicReference<ServiceInfo>()
        browser.addServiceListener(WiredHubDiscovery.TYPE, object : ServiceListener {
            override fun serviceAdded(event: ServiceEvent) {
                if (event.name == WiredHubDiscovery.instanceName(pairingID))
                    browser.requestServiceInfo(event.type, event.name, true, 1_000)
            }
            override fun serviceRemoved(event: ServiceEvent) = Unit
            override fun serviceResolved(event: ServiceEvent) {
                if (event.name == WiredHubDiscovery.instanceName(pairingID)) {
                    discovered.set(event.info)
                    resolved.countDown()
                }
            }
        })
        try {
            advertiser.configure(pairingID, local, true)
            assertTrue("Scoped mDNS not ready: $errors", ready.await(8, TimeUnit.SECONDS))
            assertTrue("Scoped mDNS did not emit serviceResolved: $errors browser=$browser", resolved.await(8, TimeUnit.SECONDS))
            val info = requireNotNull(discovered.get())
            assertEquals(WiredHubDiscovery.instanceName(pairingID), info.name)
            assertEquals(WiredHubDiscovery.TYPE, info.type)
            assertEquals(50104, info.port)
            assertEquals(listOf(local.address), info.inetAddresses.toList())
            assertTrue(info.server.startsWith("goh-hub-") && info.server.endsWith(".local."))
            assertTrue(errors.isEmpty())
            advertiser.stop()
            assertTrue(closed.await(8, TimeUnit.SECONDS))
        } finally { advertiser.close(); browser.close() }
    }

    private class ControlledDiscovery : WiredHubDiscoveryInterface {
        override var onCandidate: ((UUID, WiredInterfaceAddress, String?) -> Unit)? = null
        override var onError: ((String) -> Unit)? = null
        override fun configure(pairingID: UUID, local: WiredInterfaceAddress, publishing: Boolean) {
            if (!publishing) onCandidate?.invoke(pairingID, local, requireNotNull(local.address.hostAddress))
        }
        override fun stop() = Unit
    }
}
