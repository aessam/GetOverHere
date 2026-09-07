package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.NearbyByteConnection
import com.aessam.comeoverhere.core.NearbySocketBridge
import com.aessam.comeoverhere.core.NearbyTCPConnection
import com.aessam.comeoverhere.core.RoomAdmissionTransport
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.NearbyLaneRequest
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.RoomAdmission
import java.io.DataInputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NearbySocketBridgeTest {
    private val room = UUID.randomUUID()
    private val record = BluetoothRoomRecord(room, UUID.randomUUID(), "Walking tour", true, false)

    /** Actual TCP pair stands in only for the radio byte connection, not the protocol or admission. */
    private fun pair(): Pair<NearbyByteConnection, NearbyByteConnection> = ServerSocket(0).use { server ->
        val guest = Socket("127.0.0.1", server.localPort).apply { soTimeout = 3_000 }
        NearbyTCPConnection(guest) to NearbyTCPConnection(server.accept().apply { soTimeout = 3_000 })
    }

    @Test(timeout = 10_000) fun publicMetadataRoundtripsOverActualSockets() {
        NearbySocketBridge().use { bridge ->
            assertEquals(record, bridge.readRecord {
                val (guest, guide) = pair()
                bridge.accept(guide) { record }
                guest
            })
        }
    }

    @Test(timeout = 20_000) fun unchangedAdmissionHandlesOpenLockEditUnlockThroughBridge() {
        val admission = RoomAdmissionTransport(56013)
        val bridge = NearbySocketBridge(localConnect = { port ->
            assertEquals(50_003, port)
            NearbyTCPConnection(Socket("127.0.0.1", 56013))
        })
        try {
            admission.start(room, "23456789AB")
            fun join(code: String?): String {
                val (guest, guide) = pair()
                bridge.accept(guide) { record }
                guest.use {
                    guest.output.write(NearbyLaneRequest(NearbyLaneRequest.Lane.ADMISSION, room).encode())
                    assertEquals(0, guest.input.read())
                    val input = DataInputStream(guest.input)
                    val challenge = ByteArray(RoomAdmission.CHALLENGE_SIZE).also(input::readFully)
                    val handshake = RoomAdmission.Guest(challenge, room, code)
                    guest.output.write(handshake.request)
                    return handshake.open(ByteArray(RoomAdmission.REPLY_SIZE).also(input::readFully))
                }
            }
            assertEquals("23456789AB", join(null))
            admission.update(RoomAccessPolicy(room, "1234"))
            assertThrows(Exception::class.java) { join("wrong") }
            assertEquals("23456789AB", join("1234"))
            admission.update(RoomAccessPolicy(room, "Edited!"))
            assertThrows(Exception::class.java) { join("1234") }
            assertEquals("23456789AB", join("Edited!"))
            admission.update(RoomAccessPolicy(room, null))
            assertEquals("23456789AB", join(null))
        } finally { bridge.close(); admission.stop() }
    }

    @Test(timeout = 10_000) fun wrongRoomAndMalformedSelectorNeverOpenLocalLane() {
        NearbySocketBridge(localConnect = { error("Untrusted selector opened local lane") }).use { bridge ->
            listOf(
                NearbyLaneRequest(NearbyLaneRequest.Lane.CONTROL, UUID.randomUUID()).encode(),
                ByteArray(NearbyLaneRequest.SIZE),
            ).forEach { bytes ->
                val (guest, guide) = pair()
                bridge.accept(guide) { record }
                guest.use {
                    guest.output.write(bytes)
                    assertEquals(-1, guest.input.read())
                }
            }
        }
    }

    @Test(timeout = 10_000) fun stopClosesPendingSelectorAndBridgeCanRestart() {
        NearbySocketBridge().use { bridge ->
            val (guest, guide) = pair()
            bridge.accept(guide) { record }
            bridge.stop()
            guest.use { assertEquals(-1, guest.input.read()) }
            assertEquals(record, bridge.readRecord {
                val (nextGuest, nextGuide) = pair()
                bridge.accept(nextGuide) { record }
                nextGuest
            })
        }
    }
}
