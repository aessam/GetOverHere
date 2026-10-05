package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.WiredCompanionTransport
import com.aessam.comeoverhere.core.WiredHubDiscovery
import com.aessam.comeoverhere.core.WiredInterfaceAddress
import com.aessam.toursession.GatewayProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.net.InetAddress
import java.util.UUID

class WiredHubDiscoveryTest {
    private val pair = UUID.fromString("11111111-2222-3333-4444-555555555555")
    private val local = WiredInterfaceAddress("usb0", InetAddress.getByName("10.44.1.1"), 24)

    @Test fun discoveredCandidateMustMatchExactPairPortAndSelectedSubnet() {
        val addresses = arrayOf(InetAddress.getByName("10.44.1.2"), InetAddress.getByName("192.168.2.1"), local.address)
        val name = WiredHubDiscovery.instanceName(pair)
        assertEquals(listOf("10.44.1.2"), WiredHubDiscovery.candidates(pair, local, WiredHubDiscovery.TYPE, name, GatewayProtocol.PORT, addresses))
        assertEquals(emptyList<String>(), WiredHubDiscovery.candidates(pair, local, WiredHubDiscovery.TYPE, "$name-2", GatewayProtocol.PORT, addresses))
        assertEquals(emptyList<String>(), WiredHubDiscovery.candidates(pair, local, WiredHubDiscovery.TYPE, name, 1234, addresses))
        assertEquals(emptyList<String>(), WiredHubDiscovery.candidates(pair, local, "_other._tcp.local.", name, GatewayProtocol.PORT, addresses))
    }

    @Test fun changedAddressRecoveryStaysOnEnrolledNICAndAddressFamily() {
        val next = local.copy(address = InetAddress.getByName("10.55.2.1"))
        val wifi = next.copy(interfaceName = "wlan0")
        assertEquals(next, WiredCompanionTransport.selectRecoveryAddress("usb0", 4, local, listOf(wifi, next)))
        assertNull(WiredCompanionTransport.selectRecoveryAddress("usb0", 4, local, listOf(wifi)))
        assertEquals(local, WiredCompanionTransport.selectRecoveryAddress("usb0", 4, local, listOf(next, local)))
        val ipv6 = local.copy(address = InetAddress.getByName("fe80::1"), prefixLength = 64)
        assertEquals(ipv6, WiredCompanionTransport.selectRecoveryAddress("usb0", 4, local, listOf(ipv6)))
        assertNull(WiredCompanionTransport.selectRecoveryAddress("usb0", 4, local,
            listOf(ipv6, ipv6.copy(address = InetAddress.getByName("fe80::2")))))
        assertNull(WiredCompanionTransport.selectRecoveryAddress("usb0", 4, local, listOf(local.copy(prefixLength = 0))))
    }

    @Test fun foreignRemoteAndOverlappingEqualOrMoreSpecificRoutesAreRejected() {
        val peer = InetAddress.getByName("10.44.1.2")
        WiredCompanionTransport.requireUnambiguousPeer(local, peer, listOf(local))
        assertThrows(IllegalArgumentException::class.java) {
            WiredCompanionTransport.requireUnambiguousPeer(local, InetAddress.getByName("192.168.1.2"), listOf(local))
        }
        for (prefix in listOf<Short>(24, 25)) assertThrows(IllegalArgumentException::class.java) {
            WiredCompanionTransport.requireUnambiguousPeer(local, peer, listOf(local, local.copy(interfaceName = "wlan0", prefixLength = prefix)))
        }
        WiredCompanionTransport.requireUnambiguousPeer(local, peer, listOf(local, local.copy(interfaceName = "wlan0", prefixLength = 16)))
    }
}
