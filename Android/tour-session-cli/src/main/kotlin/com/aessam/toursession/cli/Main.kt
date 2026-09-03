package com.aessam.toursession.cli

import com.aessam.toursession.TourSessionFixtures
import com.aessam.toursession.RealtimeSequenceAudit
import com.aessam.toursession.hexToByteArray
import com.aessam.toursession.lowercaseHex
import kotlin.system.exitProcess

fun main(arguments: Array<String>) {
    try {
        when (val command = arguments.firstOrNull()) {
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
            "state" -> println(TourSessionFixtures.stateFixtureHex())
            "auth" -> println(TourSessionFixtures.authenticationFixtureHex())
            "recovery" -> println(TourSessionFixtures.simulateRecovery())
            "focus" -> println(TourSessionFixtures.simulateVisualFocus())
            null -> fail("usage: tour-session-kotlin fixture | encrypted-fixture | decode HEX[|HEX...] | decode-encrypted HEX | decode-audio HEX | audio-fixture | handshake | realtime-fixture | simulate COUNT | faults | state | auth | recovery | focus")
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
