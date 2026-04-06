package com.aessam.comeoverhere.core

import android.util.Log
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * TCP-based audio transport for cross-platform audio over WiFi hotspot.
 *
 * Broadcasting (sender): Starts a TCP server on port 50000.
 *   Clients connect, audio is streamed to all connected clients.
 *
 * Listening (receiver): Connects to the sender's TCP server.
 *   Receives audio and forwards to the callback.
 *
 * TCP avoids all the UDP broadcast interface routing issues.
 */
class UDPAudioPlane : AudioPlane {

    private val audioPort = 50000

    private val _isActive = AtomicBoolean(false)
    override val isActive: Boolean get() = _isActive.get()

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private val clientStreams = CopyOnWriteArrayList<OutputStream>()
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private val acceptExecutor = Executors.newSingleThreadExecutor()
    private var receiveThread: Thread? = null
    private var sentPacketCount = 0
    private var receivedPacketCount = 0

    /** Set by NetworkCoordinator — the hotspot gateway IP for clients to connect to */
    var hostIP: String? = null

    companion object {
        private const val TAG = "UDPAudioPlane"
    }

    // MARK: - Sender (TCP Server)

    override fun startBroadcasting(channelID: String, quality: AudioQuality) {
        // Close any lingering server socket first
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null

        _isActive.set(true)
        sentPacketCount = 0
        try {
            // Find the current LAN IPv4 so peers can connect directly on the local network.
            val ip = findLocalIPv4()
            if (hostIP == null) hostIP = ip
            Log.i(TAG, "TCP: server local IP = $ip (hostIP=$hostIP)")

            // SO_REUSEADDR prevents EADDRINUSE from TIME_WAIT sockets
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(audioPort))
            serverSocket = ss
            Log.i(TAG, "TCP: server listening on 0.0.0.0:$audioPort (reuseAddr=true)")

            // Accept client connections in background
            acceptExecutor.execute {
                while (_isActive.get()) {
                    try {
                        val client = serverSocket?.accept() ?: break
                        clientStreams.add(client.getOutputStream())
                        Log.i(TAG, "TCP: client connected from ${client.inetAddress.hostAddress}")
                    } catch (e: Exception) {
                        if (_isActive.get()) Log.e(TAG, "TCP accept error: ${e.message}")
                        break
                    }
                }
                Log.i(TAG, "TCP: accept loop ended")
            }
        } catch (e: Exception) {
            Log.e(TAG, "TCP server FAILED to start: ${e.message}", e)
            _isActive.set(false)
        }
    }

    override fun sendAudio(data: ByteArray) {
        if (!_isActive.get() || clientStreams.isEmpty()) return
        sendExecutor.execute {
            // Send length-prefixed: [4 bytes big-endian length][data]
            val header = ByteBuffer.allocate(4).putInt(data.size).array()
            sentPacketCount += 1
            if (sentPacketCount == 1) {
                Log.i(TAG, "TCP: sending first audio packet (${data.size} bytes) to ${clientStreams.size} client(s)")
            }
            val dead = mutableListOf<OutputStream>()
            for (stream in clientStreams) {
                try {
                    stream.write(header)
                    stream.write(data)
                    stream.flush()
                } catch (e: Exception) {
                    dead.add(stream)
                }
            }
            clientStreams.removeAll(dead)
        }
    }

    // MARK: - Listener (TCP Client)

    override fun startListening(channelID: String, onAudio: (ByteArray) -> Unit) {
        _isActive.set(true)
        val host = hostIP
        if (host == null) {
            Log.e(TAG, "TCP: no host IP to connect to")
            return
        }

        receiveThread = Thread {
            try {
                Log.i(TAG, "TCP: connecting to $host:$audioPort")
                val socket = Socket(host, audioPort)
                clientSocket = socket
                val input = socket.getInputStream()
                Log.i(TAG, "TCP: connected to server")

                val headerBuf = ByteArray(4)
                while (_isActive.get()) {
                    // Read length header
                    var read = 0
                    while (read < 4) {
                        val n = input.read(headerBuf, read, 4 - read)
                        if (n < 0) throw Exception("Stream ended")
                        read += n
                    }
                    val len = ByteBuffer.wrap(headerBuf).int
                    if (len <= 0 || len > 65536) continue

                    // Read audio data
                    val data = ByteArray(len)
                    read = 0
                    while (read < len) {
                        val n = input.read(data, read, len - read)
                        if (n < 0) throw Exception("Stream ended")
                        read += n
                    }
                    receivedPacketCount += 1
                    if (receivedPacketCount == 1) {
                        Log.i(TAG, "TCP: received first audio packet (${data.size} bytes)")
                    }
                    onAudio(data)
                }
            } catch (e: Exception) {
                if (_isActive.get()) Log.e(TAG, "TCP receive: ${e.message}")
            }
        }.also { it.isDaemon = true; it.start() }
    }

    override fun stop() {
        _isActive.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        try { clientSocket?.close() } catch (_: Exception) {}
        for (s in clientStreams) { try { s.close() } catch (_: Exception) {} }
        clientStreams.clear()
        serverSocket = null
        clientSocket = null
        receiveThread?.interrupt()
        receiveThread = null
        // Don't clear hostIP — it's set by NetworkCoordinator and persists across channels
        Log.i(TAG, "TCP: stopped (hostIP=$hostIP preserved)")
    }

    /** Find the current local-network IPv4 (public for NetworkCoordinator if needed). */
    fun findHotspotIPPublic(): String? = findLocalIPv4()

    private fun findLocalIPv4(): String? {
        return try {
            val allIfaces = java.net.NetworkInterface.getNetworkInterfaces()?.toList()
                ?.filter { it.isUp && !it.isLoopback }
                ?.flatMap { iface ->
                    iface.inetAddresses.toList().mapNotNull { addr ->
                        if (addr is java.net.Inet4Address) "${iface.name}:${addr.hostAddress}" else null
                    }
                } ?: emptyList()
            Log.i(TAG, "Available interfaces: $allIfaces")

            allIfaces.firstOrNull {
                val name = it.substringBefore(":")
                name.startsWith("wlan") || name.startsWith("eth")
            }?.substringAfter(":")
                ?: allIfaces.firstOrNull {
                    val ip = it.substringAfter(":")
                    ip.startsWith("192.168.") || ip.startsWith("10.") || ip.startsWith("172.")
                }?.substringAfter(":")
        } catch (e: Exception) {
            Log.e(TAG, "findLocalIPv4 failed: ${e.message}")
            null
        }
    }
}
