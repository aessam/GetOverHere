package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.BLECommand
import com.aessam.comeoverhere.core.parseBLECommand
import com.aessam.comeoverhere.core.toJson
import com.aessam.toursession.TourPackAdvert
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** ADR-082: the announce carries the pack with the same JSON keys iOS writes (tourPackID, tourPackVersion). */
class ChannelAnnouncePackTest {
    private fun announce(pack: TourPackAdvert?) = BLECommand.ChannelAnnounce(
        channelID = "00112233-4455-6677-8899-AABBCCDDEEFF", channelName = "Tour", createdBy = "guide",
        audioQuality = AudioQuality.STANDARD, wifiSSID = null, roomAdmissionVersion = 2, isRoomLocked = false, tourPack = pack,
    )

    @Test fun packRoundtripsWithIOSKeys() {
        val pack = TourPackAdvert(UUID.fromString("6f1c5c6a-0000-4000-8000-0000000000a1"), 3)
        val json = String(announce(pack).toJson())
        assertTrue(json, json.contains("\"tourPackID\":\"6F1C5C6A-0000-4000-8000-0000000000A1\""))
        assertTrue(json, json.contains("\"tourPackVersion\":3"))
        assertEquals(announce(pack), parseBLECommand(announce(pack).toJson()))
    }

    @Test fun announceWithoutPackOmitsTheKeys() {
        val json = String(announce(null).toJson())
        assertTrue(json, !json.contains("tourPack"))
        assertNull((parseBLECommand(announce(null).toJson()) as BLECommand.ChannelAnnounce).tourPack)
    }

    @Test fun iOSAnnounceJsonParses() {
        val ios = """{"channelAnnounce":{"channelID":"A","channelName":"Tour","createdBy":"g","audioQuality":"standard",""" +
            """"wifiSSID":null,"audioHostIP":null,"roomAdmissionVersion":2,"isRoomLocked":false,""" +
            """"tourPackID":"6F1C5C6A-0000-4000-8000-0000000000A1","tourPackVersion":18446744073709551615}}"""
        val parsed = parseBLECommand(ios.toByteArray()) as BLECommand.ChannelAnnounce
        assertEquals(TourPackAdvert(UUID.fromString("6f1c5c6a-0000-4000-8000-0000000000a1"), -1L), parsed.tourPack)
    }
}
