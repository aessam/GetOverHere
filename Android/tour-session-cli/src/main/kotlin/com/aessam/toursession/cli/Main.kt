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
                if (arguments.size != 2) fail("decode requires one hex argument")
                println(TourSessionFixtures.describeHello(arguments[1].hexToByteArray()))
            }
            "decode-encrypted" -> {
                if (arguments.size != 2) fail("decode-encrypted requires one hex argument")
                println(TourSessionFixtures.describeEncryptedHello(arguments[1].hexToByteArray()))
            }
            "audio-fixture" -> println(TourSessionFixtures.encodedAudioFixture().encode().lowercaseHex())
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
            null -> fail("usage: tour-session-kotlin fixture | encrypted-fixture | decode HEX | decode-encrypted HEX | audio-fixture | simulate COUNT | faults | state | auth | recovery | focus")
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
