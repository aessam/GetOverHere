package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.NearbyRealtimeConnection
import com.aessam.comeoverhere.core.NearbyTCPConnection
import java.io.DataInputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NearbyRealtimeConnectionTest {
    private fun pair(): Pair<NearbyByteConnection, NearbyByteConnection> = ServerSocket(0).use { server ->
        val guest = Socket("127.0.0.1", server.localPort).apply { soTimeout = 3_000 }
        NearbyTCPConnection(guest) to NearbyTCPConnection(server.accept().apply { soTimeout = 3_000 })
    }
    private fun frame(value: Int) = ByteBuffer.allocate(84).putInt(80).put(ByteArray(80) { value.toByte() }).array()

    @Test(timeout = 10_000) fun fourFramesInFlightRequireAcknowledgementBeforeFifth() {
        val io = Executors.newCachedThreadPool()
        val timer = Executors.newSingleThreadScheduledExecutor()
        val (sender, receiver) = pair()
        val framed = NearbyRealtimeConnection(sender, io, timer)
        try {
            val input = DataInputStream(receiver.input)
            repeat(4) { index ->
                framed.output.write(frame(index))
                assertArrayEquals(frame(index), ByteArray(84).also(input::readFully))
            }
            val fifth = io.submit { framed.output.write(frame(4)) }
            assertThrows(TimeoutException::class.java) { fifth.get(100, TimeUnit.MILLISECONDS) }
            receiver.output.write(ByteArray(4))
            fifth.get(1, TimeUnit.SECONDS)
            assertArrayEquals(frame(4), ByteArray(84).also(input::readFully))
        } finally { framed.close(); receiver.close(); io.shutdownNow(); timer.shutdownNow() }
    }

    @Test(timeout = 10_000) fun acknowledgementsNeverEnterApplicationBytesInEitherDirection() {
        val io = Executors.newCachedThreadPool()
        val timer = Executors.newSingleThreadScheduledExecutor()
        val (left, right) = pair()
        val first = NearbyRealtimeConnection(left, io, timer)
        val second = NearbyRealtimeConnection(right, io, timer)
        try {
            val firstInput = DataInputStream(first.input)
            val secondInput = DataInputStream(second.input)
            repeat(500) { value ->
                first.output.write(frame(value))
                assertArrayEquals(frame(value), ByteArray(84).also(secondInput::readFully))
                second.output.write(frame(255 - value))
                assertArrayEquals(frame(255 - value), ByteArray(84).also(firstInput::readFully))
            }
        } finally { first.close(); second.close(); io.shutdownNow(); timer.shutdownNow() }
    }

    @Test(timeout = 5_000) fun aPeerThatNeverAcknowledgesIsClosed() {
        val io = Executors.newCachedThreadPool()
        val timer = Executors.newSingleThreadScheduledExecutor()
        val (sender, receiver) = pair()
        val framed = NearbyRealtimeConnection(sender, io, timer)
        try {
            framed.output.write(frame(1))
            val input = DataInputStream(receiver.input)
            input.readFully(ByteArray(84))
            assertEquals(-1, input.read())
        } finally { framed.close(); receiver.close(); io.shutdownNow(); timer.shutdownNow() }
    }
}
