package com.aessam.comeoverhere.core

import java.net.Socket
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal enum class SocketFrameOverflowPolicy { DROP_OLDEST, DISCONNECT }

internal class SocketFrameDelivery {
    private val latch = CountDownLatch(1)
    private val result = AtomicReference<Boolean?>()

    internal fun resolve(value: Boolean) {
        if (result.compareAndSet(null, value)) latch.countDown()
    }

    fun await(deadlineNanos: Long): Boolean {
        val remaining = deadlineNanos - System.nanoTime()
        if (remaining <= 0 || !latch.await(remaining, TimeUnit.NANOSECONDS)) return false
        return result.get() == true
    }
}

internal class BoundedSocketFrameWriter(
    val socket: Socket,
    val generation: Long,
    label: String,
    private val capacity: Int,
    private val overflowPolicy: SocketFrameOverflowPolicy,
    private val sendTimeoutMillis: Long,
    private val failureHandler: (Socket, Long) -> Unit,
) : AutoCloseable {
    private data class PendingFrame(
        val data: ByteArray,
        val delivery: SocketFrameDelivery?,
    )

    private val lock = Any()
    private val pending = ArrayDeque<PendingFrame>()
    private val executor = Executors.newSingleThreadExecutor { body ->
        Thread(body, label).apply { isDaemon = true }
    }
    private var draining = false
    private var stopped = false
    private var failureReported = false

    init {
        require(capacity > 0)
        require(sendTimeoutMillis > 0)
    }

    fun enqueue(data: ByteArray, trackDelivery: Boolean = false): SocketFrameDelivery? {
        val delivery = if (trackDelivery) SocketFrameDelivery() else null
        var dropped: SocketFrameDelivery? = null
        var schedule = false
        var fail = false
        synchronized(lock) {
            if (stopped) {
                delivery?.resolve(false)
                return delivery
            }
            if (pending.size >= capacity) {
                when (overflowPolicy) {
                    SocketFrameOverflowPolicy.DROP_OLDEST -> dropped = pending.removeFirst().delivery
                    SocketFrameOverflowPolicy.DISCONNECT -> fail = true
                }
            }
            if (!fail) {
                pending.addLast(PendingFrame(data, delivery))
                if (!draining) {
                    draining = true
                    schedule = true
                }
            }
        }
        dropped?.resolve(false)
        if (fail) {
            delivery?.resolve(false)
            fail()
            return delivery
        }
        if (schedule) executor.execute(::drain)
        return delivery
    }

    override fun close() {
        val abandoned: List<SocketFrameDelivery>
        synchronized(lock) {
            if (stopped) return
            stopped = true
            abandoned = pending.mapNotNull(PendingFrame::delivery)
            pending.clear()
        }
        abandoned.forEach { it.resolve(false) }
        runCatching(socket::close)
        executor.shutdown()
    }

    private fun drain() {
        while (true) {
            val item = synchronized(lock) {
                if (stopped || pending.isEmpty()) {
                    draining = false
                    null
                } else {
                    pending.removeFirst()
                }
            } ?: return

            val sent = writeFrameWithTimeout(item.data)
            item.delivery?.resolve(sent)
            if (!sent) {
                fail()
                return
            }
        }
    }

    private fun writeFrameWithTimeout(data: ByteArray): Boolean {
        var timeout: ScheduledFuture<*>? = null
        return try {
            timeout = timeoutScheduler.schedule(
                { runCatching(socket::close) },
                sendTimeoutMillis,
                TimeUnit.MILLISECONDS,
            )
            val output = socket.getOutputStream()
            output.write(ByteBuffer.allocate(4).putInt(data.size).array())
            output.write(data)
            output.flush()
            true
        } catch (_: Exception) {
            false
        } finally {
            timeout?.cancel(false)
        }
    }

    private fun fail() {
        val report = synchronized(lock) {
            if (failureReported) false else {
                failureReported = true
                true
            }
        }
        close()
        if (report) failureHandler(socket, generation)
    }

    private companion object {
        val timeoutScheduler = Executors.newSingleThreadScheduledExecutor { body ->
            Thread(body, "socket-frame-send-timeout").apply { isDaemon = true }
        }
    }
}
