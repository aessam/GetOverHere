package com.aessam.comeoverhere.core

import android.util.Log
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.NearbyLaneRequest
import com.aessam.toursession.NearbyRealtimeQueue
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Reliable connection provided by a native nearby radio. Never serializes application payloads. */
interface NearbyByteConnection : Closeable {
    val input: InputStream
    val output: OutputStream
}

class NearbyTCPConnection(private val socket: Socket) : NearbyByteConnection {
    init { socket.tcpNoDelay = true }
    override val input: InputStream get() = socket.getInputStream()
    override val output: OutputStream get() = socket.getOutputStream()
    override fun close() = socket.close()
}

/**
 * A bounded adapter into the existing authenticated lanes. No arbitrary destination,
 * plaintext payload path, credential copy, nonce allocation or unbounded message queue.
 * One connection per lane; each direction holds one 16 KiB chunk until written.
 */
class NearbySocketBridge(
    maximumConnections: Int = 32,
    private val localConnect: (Int) -> NearbyByteConnection = { port ->
        NearbyTCPConnection(Socket().apply { connect(InetSocketAddress("127.0.0.1", port), 5_000) })
    },
) : Closeable {
    var onError: ((String) -> Unit)? = null
    private val slots = Semaphore(maximumConnections)
    private val generation = AtomicLong()
    private val connections = ConcurrentHashMap<UUID, MutableList<NearbyByteConnection>>()
    private val listeners = mutableListOf<ServerSocket>()
    private val executor = Executors.newCachedThreadPool { task -> Thread(task, "nearby-lane").apply { isDaemon = true } }
    private val timer = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "nearby-deadline").apply { isDaemon = true } }

    init { require(maximumConnections > 0) }

    @Synchronized fun stop() {
        generation.incrementAndGet()
        listeners.forEach { closeResource(it) }; listeners.clear()
        connections.keys.toList().forEach(::closeConnections)
    }

    override fun close() { stop(); executor.shutdownNow(); timer.shutdownNow() }

    fun accept(remote: NearbyByteConnection, record: () -> BluetoothRoomRecord?) {
        launch(remote) { id, attempt ->
            val deadline = timer.schedule({ closeResource(remote) }, 10, TimeUnit.SECONDS)
            try {
                val input = DataInputStream(remote.input)
                val request = NearbyLaneRequest.decode(ByteArray(NearbyLaneRequest.SIZE).also(input::readFully))
                Log.d("NearbyLane", "Guide accepted selector ${request.lane}")
                val current = requireNotNull(record()) { "Nearby room ended" }
                if (request.lane == NearbyLaneRequest.Lane.METADATA) {
                    val bytes = current.encode()
                    DataOutputStream(remote.output).apply { writeShort(bytes.size); write(bytes); flush() }
                } else {
                    require(request.roomID == current.roomID) { "Nearby room changed" }
                    val local = localConnect(requireNotNull(request.lane.localPort))
                    if (!register(id, local, attempt)) return@launch
                    remote.output.write(0); remote.output.flush()
                    deadline.cancel(false)
                    val realtime = request.lane == NearbyLaneRequest.Lane.REALTIME
                    val framed = if (realtime) NearbyRealtimeConnection(remote, executor, timer) else remote
                    if (realtime && !register(id, framed, attempt)) return@launch
                    pump(id, framed, local, realtime, drainAdmissionReply = request.lane == NearbyLaneRequest.Lane.ADMISSION)
                }
            } finally { deadline.cancel(false) }
        }
    }

    @Synchronized fun startGuest(roomID: UUID, connect: () -> NearbyByteConnection): String {
        stop()
        val attempt = generation.get()
        try {
            NearbyLaneRequest.Lane.entries.filter { it != NearbyLaneRequest.Lane.METADATA }.forEach { lane ->
                val server = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), requireNotNull(lane.localPort)), 4)
                }
                listeners.add(server)
                executor.execute {
                    while (generation.get() == attempt && !server.isClosed) {
                        try {
                            val local = NearbyTCPConnection(server.accept())
                            launch(local) { id, connectionAttempt ->
                                val remote = connect()
                                Log.d("NearbyLane", "Guest connected ${lane.name} byte stream")
                                if (!register(id, remote, connectionAttempt)) return@launch
                                val deadline = timer.schedule({ closeResource(remote) }, 10, TimeUnit.SECONDS)
                                try {
                                    remote.output.write(NearbyLaneRequest(lane, roomID).encode()); remote.output.flush()
                                    check(remote.input.read() == 0) { "Nearby room ended or changed" }
                                    Log.d("NearbyLane", "Guest selector accepted ${lane.name}")
                                    deadline.cancel(false)
                                    val realtime = lane == NearbyLaneRequest.Lane.REALTIME
                                    val framed = if (realtime) NearbyRealtimeConnection(remote, executor, timer) else remote
                                    if (realtime && !register(id, framed, connectionAttempt)) return@launch
                                    pump(id, local, framed, realtime)
                                } finally { deadline.cancel(false) }
                            }
                        } catch (error: Exception) {
                            if (generation.get() == attempt && !server.isClosed) report(error)
                            break
                        }
                    }
                }
            }
            return "127.0.0.1"
        } catch (error: Exception) { stop(); throw error }
    }

    fun readRecord(connect: () -> NearbyByteConnection): BluetoothRoomRecord {
        val remote = connect()
        remote.use {
            val deadline = timer.schedule({ closeResource(remote) }, 10, TimeUnit.SECONDS)
            try {
                remote.output.write(NearbyLaneRequest(NearbyLaneRequest.Lane.METADATA, NearbyLaneRequest.METADATA_ROOM_ID).encode())
                remote.output.flush()
                val input = DataInputStream(remote.input)
                val length = input.readUnsignedShort()
                require(length in 40..439) { "Invalid nearby room metadata length" }
                return BluetoothRoomRecord.decode(ByteArray(length).also(input::readFully))
            } finally { deadline.cancel(false) }
        }
    }

    private fun launch(initial: NearbyByteConnection, body: (UUID, Long) -> Unit) {
        if (!slots.tryAcquire()) { closeResource(initial); report(IllegalStateException("Nearby connection capacity reached")); return }
        val id = UUID.randomUUID()
        val attempt: Long
        synchronized(this) {
            attempt = generation.get()
            connections[id] = mutableListOf(initial)
        }
        executor.execute {
            try { body(id, attempt) }
            catch (error: Exception) { if (generation.get() == attempt && connections.containsKey(id)) report(error) }
            finally { closeConnections(id); slots.release() }
        }
    }

    @Synchronized private fun register(id: UUID, connection: NearbyByteConnection, attempt: Long): Boolean {
        val active = connections[id]
        if (generation.get() != attempt || active == null) { closeResource(connection); return false }
        active.add(connection)
        return true
    }

    private fun pump(id: UUID, first: NearbyByteConnection, second: NearbyByteConnection, realtime: Boolean,
                     drainAdmissionReply: Boolean = false) {
        val peerFinished = CountDownLatch(1)
        executor.execute {
            try {
                if (realtime) copyRealtime(id, second, first) else copy(second.input, first.output)
                // Native close may discard queued writes. The admission server closes after
                // its reply; let the guest receive it and close first. Bound abandoned peers.
                if (drainAdmissionReply && !peerFinished.await(5, TimeUnit.SECONDS)) {
                    Log.w("NearbyLane", "Admission reply drain deadline expired")
                }
            }
            catch (error: Exception) { if (connections.containsKey(id)) report(error) }
            finally { closeConnections(id) }
        }
        try { if (realtime) copyRealtime(id, first, second) else copy(first.input, second.output) }
        finally { peerFinished.countDown(); closeConnections(id) }
    }

    private fun copyRealtime(id: UUID, source: NearbyByteConnection, destination: NearbyByteConnection) {
        val lock = Object()
        val backlog = NearbyRealtimeQueue()
        var ended = false
        var failure: Exception? = null
        executor.execute {
            try {
                val input = DataInputStream(source.input)
                while (connections.containsKey(id)) {
                    val length = input.readInt()
                    require(length in 70..(NearbyRealtimeQueue.MAXIMUM_FRAME_SIZE - 4)) { "Invalid nearby realtime frame length" }
                    val frame = ByteArray(length).also(input::readFully)
                    val packet = java.nio.ByteBuffer.allocate(length + 4).putInt(length).put(frame).array()
                    synchronized(lock) {
                        // Public kind only. Ciphertext is verified by the existing receiving lane.
                        backlog.offer(packet, frame[7].toInt() == 0x10, System.nanoTime() / 1_000_000)
                        lock.notifyAll()
                    }
                }
            } catch (error: Exception) { synchronized(lock) { failure = error } }
            finally { synchronized(lock) { ended = true; lock.notifyAll() } }
        }
        try {
            while (connections.containsKey(id)) {
                val packet = synchronized(lock) {
                    var next = backlog.next(System.nanoTime() / 1_000_000)
                    while (next == null && !ended && connections.containsKey(id)) {
                        lock.wait()
                        next = backlog.next(System.nanoTime() / 1_000_000)
                    }
                    next
                } ?: break
                val deadline = timer.schedule({ closeResource(destination) }, 1, TimeUnit.SECONDS)
                try { destination.output.write(packet); destination.output.flush() }
                finally { deadline.cancel(false) }
            }
            synchronized(lock) { failure?.let { throw it } }
        } finally {
            closeResource(source)
            synchronized(lock) { ended = true; lock.notifyAll() }
        }
    }

    private fun copy(input: InputStream, output: OutputStream) {
        val bytes = ByteArray(16_384)
        var transferred = 0L
        while (!Thread.currentThread().isInterrupted) {
            val count = input.read(bytes)
            if (count < 0) {
                Log.d("NearbyLane", "Byte stream EOF after $transferred bytes forwarded")
                return
            }
            if (count == 0) continue
            output.write(bytes, 0, count); output.flush()
            transferred += count
        }
    }

    @Synchronized private fun closeConnections(id: UUID) { connections.remove(id)?.forEach(::closeResource) }
    private fun closeResource(value: Closeable) {
        try { value.close() } catch (error: Exception) { Log.w("NearbyLane", "Connection close failed (${error.javaClass.simpleName})") }
    }
    private fun report(error: Exception) {
        Log.w("NearbyLane", "Nearby connection failed (${error.javaClass.simpleName})")
        onError?.invoke(error.message ?: "Nearby connection failed")
    }
}
