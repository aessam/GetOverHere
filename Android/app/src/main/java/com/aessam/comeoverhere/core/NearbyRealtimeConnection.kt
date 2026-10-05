package com.aessam.comeoverhere.core

import com.aessam.toursession.NearbyRealtimeQueue
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executor
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Hop-only flow control. Zero-length records acknowledge complete frames; never reach GOH2. */
internal class NearbyRealtimeConnection(
    private val native: NearbyByteConnection,
    executor: Executor,
    private val timer: ScheduledExecutorService,
) : NearbyByteConnection {
    private val closed = AtomicBoolean()
    private val window = Semaphore(4)
    private val incoming = ArrayBlockingQueue<ByteArray>(8)
    private val writeLock = Any()
    private val acknowledgements = ArrayDeque<ScheduledFuture<*>>()
    private val acknowledgementLock = Any()
    @Volatile private var failure: Exception? = null

    init {
        executor.execute {
            try {
                val source = DataInputStream(native.input)
                while (!closed.get()) {
                    val length = source.readInt()
                    if (length == 0) {
                        synchronized(acknowledgementLock) {
                            check(acknowledgements.isNotEmpty()) { "Unexpected nearby acknowledgement" }
                            acknowledgements.removeFirst().cancel(false)
                        }
                        window.release()
                    } else {
                        require(length in 70..(NearbyRealtimeQueue.MAXIMUM_FRAME_SIZE - 4))
                        val bytes = ByteArray(length).also(source::readFully)
                        val frame = ByteBuffer.allocate(length + 4).putInt(length).put(bytes).array()
                        check(incoming.offer(frame, 1, TimeUnit.SECONDS)) { "Nearby receive window stalled" }
                        synchronized(writeLock) { native.output.write(ByteArray(4)); native.output.flush() }
                    }
                }
            } catch (error: Exception) { if (!closed.get()) failure = error }
            finally { close() }
        }
    }

    override val input = object : InputStream() {
        private var packet = byteArrayOf()
        private var position = 0
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 255
        }
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (position == packet.size) {
                packet = incoming.take(); position = 0
                if (packet.isEmpty()) {
                    incoming.offer(packet)
                    failure?.let { throw it }
                    return -1
                }
            }
            val count = minOf(length, packet.size - position)
            packet.copyInto(bytes, offset, position, position + count); position += count
            return count
        }
    }
    override val output = object : OutputStream() {
        override fun write(value: Int) = error("Nearby realtime requires complete framed writes")
        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            require(length in 74..NearbyRealtimeQueue.MAXIMUM_FRAME_SIZE)
            require(ByteBuffer.wrap(bytes, offset, length).int == length - 4)
            check(!closed.get() && window.tryAcquire(1, TimeUnit.SECONDS)) { "Nearby acknowledgement timed out" }
            synchronized(writeLock) {
                check(!closed.get()) { "Nearby realtime closed" }
                synchronized(acknowledgementLock) {
                    acknowledgements.addLast(timer.schedule({
                        failure = IllegalStateException("Nearby frame acknowledgement timed out")
                        this@NearbyRealtimeConnection.close()
                    }, 1, TimeUnit.SECONDS))
                }
                native.output.write(bytes, offset, length); native.output.flush()
            }
        }
    }
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        synchronized(acknowledgementLock) { acknowledgements.forEach { it.cancel(false) }; acknowledgements.clear() }
        window.release(4)
        incoming.clear(); incoming.offer(byteArrayOf())
        try { native.close() }
        catch (error: Exception) { android.util.Log.w("NearbyLane", "Realtime connection close failed (${error.javaClass.simpleName})") }
    }
}
