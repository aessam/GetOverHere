package com.aessam.comeoverhere.core

import android.util.Log
import com.aessam.toursession.GatewayProtocol
import java.io.Closeable
import java.net.InetAddress
import java.net.Inet6Address
import java.net.NetworkInterface
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import javax.jmdns.JmDNS
import javax.jmdns.ServiceEvent
import javax.jmdns.ServiceInfo
import javax.jmdns.ServiceListener

internal interface WiredHubDiscoveryInterface {
    var onCandidate: ((UUID, WiredInterfaceAddress, String?) -> Unit)?
    var onError: ((String) -> Unit)?
    fun configure(pairingID: UUID, local: WiredInterfaceAddress, publishing: Boolean)
    fun stop()
}

/** One explicit-interface Bonjour instance. Discovered addresses never establish trust. */
internal class WiredHubDiscovery : WiredHubDiscoveryInterface, Closeable {
    override var onCandidate: ((UUID, WiredInterfaceAddress, String?) -> Unit)? = null
    override var onError: ((String) -> Unit)? = null
    private val worker = Executors.newSingleThreadExecutor { work -> Thread(work, "wired-mdns").apply { isDaemon = true } }
    private val generation = AtomicLong()
    private var dns: JmDNS? = null // confined to worker
    var onReady: ((WiredInterfaceAddress?) -> Unit)? = null

    override fun configure(pairingID: UUID, local: WiredInterfaceAddress, publishing: Boolean) {
        val attempt = generation.incrementAndGet()
        worker.execute {
            closeCurrent()
            if (generation.get() != attempt) return@execute
            try {
                validateLocal(local)
                // Explicit address AND non-personal hostname; no JmDNS default-interface overload.
                val hostname = "goh-hub-${UUID.randomUUID()}"
                // Seed a non-personal cached hostname as HostInfo consults getHostName()
                // even with its explicit-name overload; no reverse DNS is needed here.
                val mdnsAddress = if (local.address is Inet6Address)
                    Inet6Address.getByAddress(hostname, local.address.address, local.address.scopeId)
                    else InetAddress.getByAddress(hostname, local.address.address)
                val owner = JmDNS.create(mdnsAddress, hostname)
                dns = owner
                owner.setDelegate { _, _ ->
                    if (generation.get() == attempt) report(IllegalStateException("mDNS could not recover its selected-interface socket"))
                }
                validateLocal(local)
                check(owner.inetAddress == local.address && NetworkInterface.getByInetAddress(owner.inetAddress)?.name == local.interfaceName) {
                    "mDNS did not retain the selected wired interface"
                }
                if (generation.get() != attempt) { closeCurrent(); return@execute }
                val name = instanceName(pairingID)
                if (publishing) {
                    val info = ServiceInfo.create(TYPE, name, GatewayProtocol.PORT, 0, 0, mapOf("v" to "1"))
                    owner.registerService(info)
                    check(info.name == name) { "Wired companion service name collided" }
                } else owner.addServiceListener(TYPE, object : ServiceListener {
                    override fun serviceAdded(event: ServiceEvent) {
                        if (generation.get() == attempt && event.name == name)
                            owner.requestServiceInfo(TYPE, name, true, 1_000)
                    }
                    override fun serviceRemoved(event: ServiceEvent) {
                        if (generation.get() == attempt && event.name == name) onCandidate?.invoke(pairingID, local, null)
                    }
                    override fun serviceResolved(event: ServiceEvent) {
                        if (generation.get() != attempt) return
                        try {
                            validateLocal(local)
                            candidates(pairingID, local, event.type, event.name, event.info.port, event.info.inetAddresses)
                                .forEach { onCandidate?.invoke(pairingID, local, it) }
                        } catch (error: Exception) { if (generation.get() == attempt) report(error) }
                    }
                })
                if (generation.get() == attempt) onReady?.invoke(local) else closeCurrent()
            } catch (error: Exception) { closeCurrent(); if (generation.get() == attempt) report(error) }
        }
    }
    override fun stop() { generation.incrementAndGet(); worker.execute(::closeCurrent) }
    override fun close() { stop(); worker.shutdown() }
    private fun closeCurrent() {
        val previous = dns; dns = null
        try { previous?.close() } catch (error: Exception) { Log.w("WiredHubDiscovery", "mDNS close failed (${error.javaClass.simpleName})") }
        if (previous != null) onReady?.invoke(null)
    }
    private fun report(error: Exception) {
        Log.w("WiredHubDiscovery", "Wired discovery failed (${error.javaClass.simpleName})")
        onError?.invoke(error.message ?: "Wired discovery failed")
    }
    companion object {
        const val TYPE = "_goh-hub._tcp.local."
        fun instanceName(pairingID: UUID) = "goh-$pairingID"
        fun candidates(pairingID: UUID, local: WiredInterfaceAddress, type: String, name: String,
                       port: Int, addresses: Array<InetAddress>): List<String> {
            if (!type.equals(TYPE, ignoreCase = true) || name != instanceName(pairingID) || port != GatewayProtocol.PORT) return emptyList()
            return addresses.take(16).filter { !it.isAnyLocalAddress && !it.isMulticastAddress &&
                it != local.address && local.contains(it) }.map { requireNotNull(it.hostAddress).substringBefore('%') }.distinct()
        }
        private fun validateLocal(local: WiredInterfaceAddress) {
            val nic = requireNotNull(NetworkInterface.getByName(local.interfaceName)) { "Selected wired interface disappeared" }
            check(nic.isUp && nic.inetAddresses.toList().contains(local.address) &&
                NetworkInterface.getByInetAddress(local.address)?.name == nic.name && local.prefixLength > 0 &&
                local.prefixLength <= local.address.address.size * 8) { "Selected wired address is no longer owned by its interface" }
        }
    }
}
