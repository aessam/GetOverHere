package com.aessam.toursession.cli

import com.aessam.toursession.TourSessionFixtures
import com.aessam.toursession.RealtimeSequenceAudit
import com.aessam.toursession.RoomAdmission
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.NearbyLaneRequest
import com.aessam.toursession.NearbyRealtimeQueue
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import java.util.UUID
import com.aessam.toursession.hexToByteArray
import com.aessam.toursession.lowercaseHex
import kotlin.system.exitProcess

fun main(arguments: Array<String>) {
    try {
        when (val command = arguments.firstOrNull()) {
            "sign-guide" -> {
                val frame = TourSessionFixtures.encryptedRealtimeFixture()
                val signer = GuideFrameSigner(frame.sessionId, frame.senderId)
                println(signer.publicKey.lowercaseHex())
                println(signer.sign(frame).encode().lowercaseHex())
            }
            "verify-guide" -> {
                require(arguments.size == 3) { "verify-guide requires PINNED_KEY_HEX PACKET_HEX" }
                val frame = TourSessionFixtures.encryptedRealtimeFixture()
                val verifier = GuideFrameVerifier(arguments[1].hexToByteArray(), frame.sessionId, frame.senderId)
                println(verifier.verify(arguments[2].hexToByteArray()).encode().lowercaseHex())
            }
            "nearby-fixture" -> {
                NearbyLaneRequest.Lane.entries.forEach { lane ->
                    val room = if (lane == NearbyLaneRequest.Lane.METADATA) NearbyLaneRequest.METADATA_ROOM_ID
                        else UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
                    println(NearbyLaneRequest(lane, room).encode().lowercaseHex())
                }
                val queue = NearbyRealtimeQueue()
                queue.offer(byteArrayOf(99), false, 0)
                repeat(100) { queue.offer(byteArrayOf(it.toByte()), true, it.toLong()) }
                while (true) { val bytes = queue.next(245) ?: break; println(bytes.lowercaseHex()) }
                println("dropped=${queue.dropped}")
            }
            "room-guide", "room-guest" -> {
                require(arguments.size == 3) { "room-guide/room-guest requires UUID CODE (use - for open)" }
                val id = UUID.fromString(arguments[1])
                val code = arguments[2].takeUnless { it == "-" }
                fun receive() = requireNotNull(readlnOrNull()) { "Admission input closed" }.hexToByteArray()
                if (command == "room-guide") {
                    val guide = RoomAdmission.Guide(id, RoomAccessPolicy(id, code))
                    println(guide.challenge.lowercaseHex())
                    println(guide.reply(receive(), "23456789AB").lowercaseHex())
                } else {
                    val guest = RoomAdmission.Guest(receive(), id, code)
                    println(guest.request.lowercaseHex())
                    println(guest.open(receive()))
                }
            }
            "fixture" -> println(TourSessionFixtures.helloEnvelope().encode().lowercaseHex())
            "encrypted-fixture" -> println(TourSessionFixtures.encryptedHelloFixture().encode().lowercaseHex())
            "decode" -> {
                if (arguments.size != 2) fail("decode requires one |-separated hex argument")
                println(TourSessionFixtures.describeEnvelopes(arguments[1]))
            }
            "decode-encrypted" -> {
                if (arguments.size != 2) fail("decode-encrypted requires one hex argument")
                println(TourSessionFixtures.describeSealed(arguments[1].hexToByteArray()))
            }
            "decode-audio" -> {
                if (arguments.size != 2) fail("decode-audio requires one hex argument")
                println(TourSessionFixtures.describeAudioFrame(arguments[1].hexToByteArray()))
            }
            "audio-fixture" -> println(TourSessionFixtures.encodedAudioFixture().encode().lowercaseHex())
            "handshake" -> println(TourSessionFixtures.handshakeFixtureHex())
            "realtime-fixture" -> println(TourSessionFixtures.encryptedRealtimeFixture().encode().lowercaseHex())
            "simulate" -> {
                val count = arguments.getOrNull(1)?.toIntOrNull()
                if (arguments.size != 2 || count == null || count < 0) {
                    fail("simulate requires a non-negative integer")
                }
                println(TourSessionFixtures.simulateParticipants(count))
            }
            "faults" -> println(RealtimeSequenceAudit.analyze(listOf(1, 2, 2, 5, 4, 7)).report)
            "playout" -> println(TourSessionFixtures.simulatePlayout())
            "state" -> println(TourSessionFixtures.stateFixtureHex())
            "auth" -> println(TourSessionFixtures.authenticationFixtureHex())
            "recovery" -> println(TourSessionFixtures.simulateRecovery())
            "focus" -> println(TourSessionFixtures.simulateVisualFocus())
            null -> fail("usage: tour-session-kotlin fixture | encrypted-fixture | decode HEX[|HEX...] | decode-encrypted HEX | decode-audio HEX | audio-fixture | handshake | realtime-fixture | nearby-fixture | simulate COUNT | faults | playout | state | auth | recovery | focus")
            else -> fail("unknown command: $command")
        }
    } catch (error: Exception) {
        System.err.println("error: ${error.message}")
        exitProcess(1)
    }
}

private fun fail(message: String): Nothing {
    throw IllegalArgumentException(message)
}
