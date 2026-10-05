package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.WiredCompanionTransport
import com.aessam.comeoverhere.core.WiredInterfaceAddress
import com.aessam.toursession.AllowedTransportPolicy
import com.aessam.toursession.SessionRouteAvailability
import com.aessam.toursession.SessionTransportRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.Inet6Address
import java.net.NetworkInterface

class GatewayRoutePolicyTest {
    @Test fun strictAwarePolicyNeverOffersLANOrBluetoothFallback() {
        val available = SessionRouteAvailability(true, true, true).orderedRoutes
        assertEquals(listOf(SessionTransportRoute.WIFI_AWARE), available.filter(AllowedTransportPolicy.ANDROID_AWARE_ONLY::permits))
        assertTrue(SessionRouteAvailability(true, false, true).orderedRoutes.filter(AllowedTransportPolicy.ANDROID_AWARE_ONLY::permits).isEmpty())
    }
    @Test fun numericWiredAddressRejectsHostnamesAndMalformedIPv4() {
        listOf("example.com", "127.1", "10.0.0.256", "10.0.0.1 ", "", "a:b.example").forEach {
            assertThrows(IllegalArgumentException::class.java) { WiredCompanionTransport.numericAddress(it) }
        }
        assertEquals("10.255.230.7", WiredCompanionTransport.numericAddress("10.255.230.7").hostAddress)
    }
    @Test fun wiredSubnetCheckDoesNotAcceptUnrelatedLANOrDifferentFamily() {
        val link = WiredInterfaceAddress("test-usb", InetAddress.getByName("10.0.7.1"), 24)
        assertTrue(link.contains(InetAddress.getByName("10.0.7.2")))
        assertEquals(false, link.contains(InetAddress.getByName("192.168.1.2")))
        assertEquals(false, link.contains(InetAddress.getByName("::1")))
        assertEquals(false, link.copy(prefixLength = 0).contains(InetAddress.getByName("192.168.1.2")))
        assertEquals(false, link.copy(prefixLength = 33).contains(InetAddress.getByName("10.0.7.2")))
    }
    @Test fun remoteIPv6ScopeIsReplacedWithSelectedLocalUSBInterface() {
        val nic = NetworkInterface.getByInetAddress(InetAddress.getByName("127.0.0.1"))
        val local = WiredInterfaceAddress(nic.name, Inet6Address.getByAddress(null,
            InetAddress.getByName("fe80::1").address, nic.index), 64)
        val peer = WiredCompanionTransport.numericAddress("fe80::2%iphone-interface-does-not-exist", local) as Inet6Address
        assertEquals(nic.index, peer.scopeId)
        assertTrue(local.contains(peer))
        assertEquals(false, local.copy(prefixLength = 129).contains(peer))
    }
}
