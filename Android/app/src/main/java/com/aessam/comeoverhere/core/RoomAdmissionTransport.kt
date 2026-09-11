package com.aessam.comeoverhere.core

import android.util.Log
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.RoomAdmissionV2
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.AdmittedRoomCredentials
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.io.EOFException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.UUID
import java.util.concurrent.Semaphore
import kotlin.concurrent.thread

interface RoomAdmissionInterface {
    fun start(sessionID: UUID, sessionCode: String, signer: GuideFrameSigner)
    fun update(policy: RoomAccessPolicy)
    fun stop()
    fun join(host: String, sessionID: UUID, expectedGuideID: UUID, code: String?): AdmittedRoomCredentials
}

/** Reachability failed before receiving any challenge bytes. Once credentials may have been
 * sent, I/O failure is terminal: a closed reply can mean wrong-code rejection, not route loss.
 */
class RoomAdmissionTransportError(cause: IOException) : IOException("Cannot reach the guide for room admission.", cause)

class RoomAdmissionTransport(private val port: Int = RoomAdmissionV2.PORT) : RoomAdmissionInterface {
    private val lock = Any()
    private val slots = Semaphore(8)
    private var listener: ServerSocket? = null
    private val pending = mutableSetOf<Socket>()
    private var policy: RoomAccessPolicy? = null
    private var revision = 0L

    override fun start(sessionID: UUID, sessionCode: String, signer: GuideFrameSigner) {
        stop()
        val open = RoomAccessPolicy(sessionID, null)
        val server = ServerSocketChannel.open().socket()
        try {
            server.reuseAddress = true
            server.bind(InetSocketAddress(port), 8)
        } catch (error: Exception) {
            server.close()
            throw IllegalStateException("Cannot open room admission port $port.", error)
        }
        synchronized(lock) { listener = server; policy = open; revision++ }
        thread(name = "room-admission-accept", isDaemon = true) {
            while (!server.isClosed) {
                val client = try { server.accept() } catch (error: Exception) {
                    if (!server.isClosed) Log.e("RoomAdmission", "Accept failed (${error.javaClass.simpleName})")
                    break
                }
                if (!slots.tryAcquire()) { client.close(); continue }
                val snapshot = synchronized(lock) {
                    if (listener !== server) null else {
                        pending.add(client)
                        requireNotNull(policy) to revision
                    }
                }
                if (snapshot == null) { client.close(); slots.release(); continue }
                thread(name = "room-admission-handshake", isDaemon = true) {
                    try {
                        client.use {
                            client.soTimeout = 5_000
                            val guide = RoomAdmissionV2.Guide(sessionID, snapshot.first, signer)
                            client.getOutputStream().write(guide.challenge)
                            val request = read(client, RoomAdmissionV2.REQUEST_SIZE)
                            val reply = guide.reply(request, sessionCode)
                            val channel = requireNotNull(client.channel)
                            channel.configureBlocking(false)
                            synchronized(lock) {
                                check(listener === server && revision == snapshot.second) { "Room access changed." }
                                writeReplyOnce(channel, reply)
                            }
                        }
                    } catch (error: Exception) {
                        Log.i("RoomAdmission", "Admission rejected or disconnected (${error.javaClass.simpleName})")
                    } finally {
                        synchronized(lock) { pending.remove(client) }
                        slots.release()
                    }
                }
            }
        }
    }

    override fun update(policy: RoomAccessPolicy) = synchronized(lock) {
        check(listener != null) { "Room access changed." }
        this.policy = policy
        revision++
        pending.forEach { it.close() }
    }

    override fun stop() = synchronized(lock) {
        listener?.close()
        listener = null
        policy = null
        revision++
        pending.forEach { it.close() }
    }

    override fun join(host: String, sessionID: UUID, expectedGuideID: UUID, code: String?): AdmittedRoomCredentials = Socket().use { socket ->
        socket.soTimeout = 5_000
        try {
            socket.connect(InetSocketAddress(host, port), 5_000)
        } catch (error: IOException) { throw RoomAdmissionTransportError(error) }
        val challenge = read(socket, RoomAdmissionV2.CHALLENGE_SIZE, beforeChallenge = true)
        val guest = RoomAdmissionV2.Guest(challenge, sessionID, expectedGuideID, code)
        socket.getOutputStream().write(guest.request)
        guest.open(read(socket, RoomAdmissionV2.REPLY_SIZE))
    }

    private fun read(socket: Socket, count: Int, beforeChallenge: Boolean = false): ByteArray {
        val bytes = ByteArray(count)
        val input = socket.getInputStream()
        val deadline = System.nanoTime() + 5_000_000_000L
        var offset = 0
        while (offset < count) {
            try {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) throw SocketTimeoutException("Room admission timed out.")
                socket.soTimeout = (remaining / 1_000_000L).coerceAtLeast(1).toInt()
                val received = input.read(bytes, offset, count - offset)
                if (received <= 0) throw EOFException("Room admission failed. Check the code and try again.")
                offset += received
            } catch (error: IOException) {
                if (beforeChallenge && offset == 0) throw RoomAdmissionTransportError(error)
                throw error
            }
        }
        return bytes
    }

    companion object {
        /** A partial AEAD reply fails closed; never wait for socket writability under the policy lock. */
        internal fun writeReplyOnce(channel: SocketChannel, reply: ByteArray) {
            check(!channel.isBlocking && reply.size == RoomAdmissionV2.REPLY_SIZE)
            check(channel.write(ByteBuffer.wrap(reply)) == reply.size) { "Room admission reply backpressured." }
        }
    }
}
