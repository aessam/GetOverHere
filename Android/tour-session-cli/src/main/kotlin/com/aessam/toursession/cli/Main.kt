package com.aessam.toursession.cli

import com.aessam.toursession.AudioReadinessPayload
import com.aessam.toursession.AudioReadinessStatus
import com.aessam.toursession.GatewayPairingMessage
import com.aessam.toursession.GatewayPairingRole
import com.aessam.toursession.GatewayLaneRequest
import com.aessam.toursession.GatewayLane
import com.aessam.toursession.GatewayRoomDescriptor

import com.aessam.toursession.TourSessionFixtures
import com.aessam.toursession.RealtimeSequenceAudit
import com.aessam.toursession.RoomAdmission
import com.aessam.toursession.RoomAdmissionV2
import com.aessam.toursession.BluetoothLanePSMs
import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.RoomAccessPolicy
import com.aessam.toursession.NearbyLaneRequest
import com.aessam.toursession.NearbyRealtimeQueue
import com.aessam.toursession.GuideFrameSigner
import com.aessam.toursession.GuideFrameVerifier
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionFrameOpenResult
import com.aessam.toursession.SessionFrameOpener
import com.aessam.toursession.SessionFrameSealer
import com.aessam.toursession.SessionGuidePin
import com.aessam.toursession.SessionLane
import com.aessam.toursession.SessionMessageKind
import java.util.UUID
import com.aessam.toursession.hexToByteArray
import com.aessam.toursession.lowercaseHex
import kotlin.system.exitProcess

fun main(arguments: Array<String>) {
    try {
        when (val command = arguments.firstOrNull()) {
            "gateway-fixture" -> gatewayFixture()
            "gateway-decode" -> {
                require(arguments.size == 3)
                println(when (arguments[1]) {
                    "pairing" -> GatewayPairingMessage.decode(arguments[2].hexToByteArray()).encode().lowercaseHex()
                    "lane" -> GatewayLaneRequest.decode(arguments[2].hexToByteArray()).encode().lowercaseHex()
                    "descriptor" -> GatewayRoomDescriptor.decode(arguments[2].hexToByteArray()).encode().lowercaseHex()
                    "qr" -> GatewayPairingMessage.fromQR(arguments[2]).qrText()
                    else -> error("Unsupported gateway message kind")
                })
            }
            "audio-readiness-fixture" -> println(AudioReadinessPayload(
                AudioReadinessStatus.PLAYING, 0x0102030405060708uL).encode().lowercaseHex())
            "bluetooth-v2-fixture" -> println(BluetoothRoomRecord(
                UUID.fromString("00112233-4455-6677-8899-aabbccddeeff"),
                UUID.fromString("ffeeddcc-bbaa-9988-7766-554433221100"), "Tour", true, true, 2).encode().lowercaseHex())
            "bluetooth-lanes-fixture" -> println(BluetoothLanePSMs(128, 129, 256, 65535).encode().lowercaseHex())
            "room-v2-guide", "room-v2-guest" -> {
                require(arguments.size == 4) {
                    "room-v2-guide/room-v2-guest requires SESSION_UUID GUIDE_UUID CODE (use - for open)"
                }
                val session = UUID.fromString(arguments[1])
                val guideId = UUID.fromString(arguments[2])
                val code = arguments[3].takeUnless { it == "-" }
                fun receive() = requireNotNull(readlnOrNull()) { "Admission input closed" }.hexToByteArray()
                if (command == "room-v2-guide") {
                    val signer = GuideFrameSigner(session, guideId)
                    val guide = RoomAdmissionV2.Guide(session, RoomAccessPolicy(session, code), signer)
                    println(guide.challenge.lowercaseHex())
                    println(guide.reply(receive(), "23456789AB").lowercaseHex())
                    val credential = SessionCredential.derive("23456789AB", session)
                    val envelope = SessionEnvelope(lane = SessionLane.CONTROL, kind = SessionMessageKind.LEAVE,
                        sequence = 1, sessionId = session, senderId = guideId, payload = byteArrayOf())
                    val sealed = SessionFrameSealer(credential).seal(envelope, UUID.randomUUID())
                    println(signer.sign(sealed).encode().lowercaseHex())
                    println(signer.publicKey.lowercaseHex())
                } else {
                    val guest = RoomAdmissionV2.Guest(receive(), session, guideId, code)
                    println(guest.request.lowercaseHex())
                    val admitted = guest.open(receive())
                    SessionGuidePin().accept(admitted.guideIdentity)
                    val verifier = GuideFrameVerifier(admitted.guideIdentity.publicKey, session, guideId)
                    val sealed = verifier.verify(receive())
                    val credential = SessionCredential.derive(admitted.mediaSecret, session)
                    val opened = SessionFrameOpener(credential).open(sealed)
                    require(opened is SessionFrameOpenResult.Opened && opened.envelope.kind == SessionMessageKind.LEAVE &&
                        opened.envelope.sequence == 1L && opened.envelope.payload.isEmpty()) { "Admitted guide frame roundtrip failed" }
                    println(admitted.mediaSecret)
                    println(admitted.guideIdentity.publicKey.lowercaseHex())
                    println("signed-guide-ok")
                }
            }
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
            null -> fail("usage: tour-session-kotlin fixture | encrypted-fixture | decode HEX[|HEX...] | decode-encrypted HEX | decode-audio HEX | audio-fixture | handshake | realtime-fixture | nearby-fixture | bluetooth-lanes-fixture | simulate COUNT | faults | playout | state | auth | recovery | focus")
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

private fun gatewayFixture() {
    val pairing = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
    val room = UUID.fromString("10213243-5465-7687-98a9-bacbdcedfe0f")
    val guide = UUID.fromString("20314253-6475-8697-a8b9-cadbecfd0e1f")
    val offer = GatewayPairingMessage(GatewayPairingRole.OFFER, pairing, room, guide, 121_000,
        ByteArray(32) { 0x11 }, ByteArray(32) { 0x22 }, ByteArray(32) { 0x11 }, "10.255.230.7", 50_104)
    val response = offer.copy(role = GatewayPairingRole.RESPONSE, certificateFingerprint = ByteArray(32) { 0x33 }, host = "", port = 0)
    println(offer.encode().lowercaseHex()); println(response.encode().lowercaseHex())
    println(offer.qrText()); println(response.qrText())
    GatewayLane.entries.forEach { println(GatewayLaneRequest(pairing, room, if (it == GatewayLane.HUB_CONTROL) 0 else 1, it).encode().lowercaseHex()) }
    println(GatewayRoomDescriptor(3, 5, BluetoothRoomRecord(room, guide, "Tour — جولة", false, true, 2),
        byteArrayOf(4) + ByteArray(64) { 0x44 }).encode().lowercaseHex())
}
