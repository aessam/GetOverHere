package com.aessam.toursession

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class SessionProtocolTest {
    @Test
    fun goldenHelloFrameIsStable() {
        val encoded = TourSessionFixtures.helloEnvelope().encode()
        assertEquals(
            "474f4832020102010000000000000000002a00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f0000004002020000000300074775657374203702000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf",
            encoded.lowercaseHex(),
        )
        assertEquals(TourSessionFixtures.helloEnvelope(), SessionEnvelope.decode(encoded))
        assertArrayEquals(encoded, SessionEnvelope.decode(encoded).encode())
    }

    @Test
    fun encryptedFrameIsRouteIndependentAuthenticatedAndReplayDetectable() {
        val credential = TourSessionFixtures.fixtureCredential()
        val sealer = SessionFrameSealer(credential)
        val logical = TourSessionFixtures.helloEnvelope()
        val first = sealer.seal(logical, TourSessionFixtures.streamId)
        val second = sealer.seal(logical, TourSessionFixtures.streamId)

        assertEquals(first, second)
        assertArrayEquals(first.encode(), second.encode())
        assertEquals(
            "474f4832040002010000000000000000002a00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f0f1e2d3c4b5a69788796a5b4c3d2e1f000000050eaa9f8c5e519d5a5fc368f8dbfe6d7e45d70eb96c32dd250490c747f03506c02a397edbef6eb9dfab3c4fd42eca6b528684123fa95a9649bb3e5ad5ee146d2953f14667726159f3dcfd266a5f1d98fa6",
            first.encode().lowercaseHex(),
        )
        assertFalse(String(first.encode(), Charsets.ISO_8859_1).contains("Guest 7"))

        val opener = SessionFrameOpener(credential)
        val opened = opener.open(first)
        assertTrue(opened is SessionFrameOpenResult.Opened)
        assertEquals(SealedSessionEnvelope.MAJOR_VERSION, (opened as SessionFrameOpenResult.Opened).envelope.majorVersion)
        assertArrayEquals(logical.payload, opened.envelope.payload)
        assertEquals(SessionFrameOpenResult.Duplicate(first.identity), opener.open(second))

        val changed = logical.copy(payload = "different plaintext".toByteArray())
        val reuse = assertThrows(SessionFrameSecurityException::class.java) {
            sealer.seal(changed, TourSessionFixtures.streamId)
        }
        assertEquals("session frame identity was reused: ${first.identity}", reuse.message)
    }

    @Test
    fun encryptedFrameRejectsTamperingAndAnotherTourCredential() {
        val sealed = TourSessionFixtures.encryptedHelloFixture()
        val tampered = sealed.encode().also { bytes ->
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        }
        val decodedTampered = SealedSessionEnvelope.decode(tampered)
        val correctOpener = SessionFrameOpener(TourSessionFixtures.fixtureCredential())
        assertEquals(
            "session frame authentication failed",
            assertThrows(SessionFrameSecurityException::class.java) {
                correctOpener.open(decodedTampered)
            }.message,
        )

        val wrongCredential = SessionCredential.derive("23456789AC", TourSessionFixtures.sessionId)
        val wrongOpener = SessionFrameOpener(wrongCredential)
        assertEquals(
            "session frame authentication failed",
            assertThrows(SessionFrameSecurityException::class.java) {
                wrongOpener.open(sealed)
            }.message,
        )
    }

    @Test
    fun encryptedFrameAuthenticatesAndPreservesReceivedMinorVersion() {
        val credential = TourSessionFixtures.fixtureCredential()
        val logical = TourSessionFixtures.helloEnvelope()
        val sealed = SessionFrameSealer(
            credential = credential,
            protocolMinorVersion = 1,
        ).seal(logical, TourSessionFixtures.streamId)

        assertEquals(1, sealed.minorVersion)
        val decoded = SealedSessionEnvelope.decode(sealed.encode())
        assertEquals(1, decoded.minorVersion)
        val opened = SessionFrameOpener(credential).open(decoded) as SessionFrameOpenResult.Opened
        assertEquals(1, opened.envelope.minorVersion)
        assertArrayEquals(logical.payload, opened.envelope.payload)

        val tamperedMinor = sealed.encode().also { it[5] = 2 }
        assertEquals(
            "session frame authentication failed",
            assertThrows(SessionFrameSecurityException::class.java) {
                SessionFrameOpener(credential).open(SealedSessionEnvelope.decode(tamperedMinor))
            }.message,
        )
    }

    @Test
    fun replayWindowRejectsAcceptedFrameAfterSequenceEviction() {
        val credential = TourSessionFixtures.fixtureCredential()
        val fixture = TourSessionFixtures.helloEnvelope()
        val sealer = SessionFrameSealer(credential)
        val frames = (1L..4L).map { sequence ->
            sealer.seal(
                fixture.copy(sequence = sequence),
                TourSessionFixtures.streamId,
            )
        }
        val opener = SessionFrameOpener(credential, replayWindow = 3)

        assertTrue(opener.open(frames[1]) is SessionFrameOpenResult.Opened)
        assertTrue(opener.open(frames[0]) is SessionFrameOpenResult.Opened)
        assertTrue(opener.open(frames[2]) is SessionFrameOpenResult.Opened)
        assertEquals(SessionFrameOpenResult.Duplicate(frames[0].identity), opener.open(frames[0]))
        assertTrue(opener.open(frames[3]) is SessionFrameOpenResult.Opened)
        assertEquals(
            "session frame fell outside replay window: ${frames[0].identity}",
            assertThrows(SessionFrameSecurityException::class.java) {
                opener.open(frames[0])
            }.message,
        )
    }

    @Test
    fun encryptedProtocolRejectsLegacyMajorExplicitly() {
        listOf(SessionEnvelope.MAJOR_VERSION, 3).forEach { legacy ->
            val bytes = TourSessionFixtures.encryptedHelloFixture().encode().also {
                it[4] = legacy.toByte()
            }
            val error = assertThrows(UnsupportedSessionVersionException::class.java) {
                SealedSessionEnvelope.decode(bytes)
            }
            assertEquals(legacy, error.receivedMajorVersion)
            assertEquals(SealedSessionEnvelope.MAJOR_VERSION, error.supportedMajorVersion)
        }
    }

    @Test
    fun plaintextProtocolRejectsLegacyMajorExplicitly() {
        val bytes = TourSessionFixtures.helloEnvelope().encode().also {
            it[4] = SealedSessionEnvelope.MAJOR_VERSION.toByte()
        }
        val error = assertThrows(UnsupportedSessionVersionException::class.java) {
            SessionEnvelope.decode(bytes)
        }
        assertEquals(SealedSessionEnvelope.MAJOR_VERSION, error.receivedMajorVersion)
        assertEquals(SessionEnvelope.MAJOR_VERSION, error.supportedMajorVersion)
        assertEquals(
            "unsupported major version ${SealedSessionEnvelope.MAJOR_VERSION}; " +
                "this build requires ${SessionEnvelope.MAJOR_VERSION}",
            error.message,
        )
    }

    @Test
    fun tourPackOrderingIsUtf8ByteOrderWithExactDedup() {
        fun asset(assetID: String, order: Long = 0) = TourAssetDescriptor(
            assetID,
            TourAssetKind.SLIDE,
            "ab".repeat(32),
            1,
            order,
            "image/jpeg",
        )
        val astral = "plaza-\uD83D\uDDFA"
        val fullwidth = "plaza-\uFF5E"
        val tie = TourPackManifestPayload(
            TourSessionFixtures.packId,
            1,
            "Tie",
            listOf(asset(astral), asset(fullwidth)),
        )
        assertEquals(listOf(fullwidth, astral), tie.assets.map { it.assetID })
        assertEquals("876543210fedcba9876543210fedcba90000000000000001000354696500020009706c617a612defbd9e01abababababababababababababababababababababababababababababababab000000000000000100000000000a696d6167652f6a706567000a706c617a612df09f97ba01abababababababababababababababababababababababababababababababab000000000000000100000000000a696d6167652f6a706567", tie.encode().lowercaseHex())
        assertArrayEquals(tie.encode(), TourPackManifestPayload.decode(tie.encode()).encode())

        val nfc = "caf\u00E9"
        val nfd = "cafe\u0301"
        val canonical = TourPackManifestPayload(
            TourSessionFixtures.packId,
            1,
            "Tie",
            listOf(asset(nfc), asset(nfd)),
        )
        assertEquals(2, canonical.assets.size)
        assertArrayEquals(
            byteArrayOf(0x63, 0x61, 0x66, 0x65, 0xCC.toByte(), 0x81.toByte()),
            canonical.assets[0].assetID.toByteArray(Charsets.UTF_8),
        )
        assertArrayEquals(canonical.encode(), TourPackManifestPayload.decode(canonical.encode()).encode())

        val signed = TourPackManifestPayload(
            TourSessionFixtures.packId,
            1,
            "Tie",
            listOf(asset("é"), asset("z")),
        )
        assertEquals(listOf("z", "é"), signed.assets.map { it.assetID })
        val prefix = TourPackManifestPayload(
            TourSessionFixtures.packId,
            1,
            "Tie",
            listOf(asset("ab"), asset("a")),
        )
        assertEquals(listOf("a", "ab"), prefix.assets.map { it.assetID })

        val duplicate = assertThrows(SessionProtocolException::class.java) {
            TourPackManifestPayload(
                TourSessionFixtures.packId,
                1,
                "Tie",
                listOf(asset("gate-left"), asset("gate-left", 1)),
            )
        }
        assertEquals("duplicate tour asset ID gate-left", duplicate.message)
    }

    @Test
    fun slideManifestOrderingIsUtf8ByteOrderWithExactDedup() {
        fun slide(slideID: String, order: Long = 0) = SlideAssetDescriptor(
            slideID,
            "ab".repeat(32),
            1,
            order,
            "image/jpeg",
        )
        val astral = "gate-\uD83D\uDDFA"
        val fullwidth = "gate-\uFF5E"
        val tie = AssetManifestPayload(
            TourSessionFixtures.deckId,
            1,
            listOf(slide(astral), slide("gate-left", 1), slide(fullwidth)),
        )
        assertEquals(listOf(fullwidth, astral, "gate-left"), tie.assets.map { it.slideID })
        assertArrayEquals(tie.encode(), AssetManifestPayload.decode(tie.encode()).encode())
        assertEquals(
            listOf(fullwidth, astral, "gate-left"),
            AssetManifestPayload.decode(tie.encode()).assets.map { it.slideID },
        )

        val signed = AssetManifestPayload(TourSessionFixtures.deckId, 1, listOf(slide("é"), slide("z")))
        assertEquals(listOf("z", "é"), signed.assets.map { it.slideID })
        val prefix = AssetManifestPayload(TourSessionFixtures.deckId, 1, listOf(slide("ab"), slide("a")))
        assertEquals(listOf("a", "ab"), prefix.assets.map { it.slideID })

        val duplicate = assertThrows(SessionProtocolException::class.java) {
            AssetManifestPayload(TourSessionFixtures.deckId, 1, listOf(slide("gate-left"), slide("gate-left", 1)))
        }
        assertEquals("duplicate slide ID gate-left", duplicate.message)
    }

    @Test
    fun handshakeFixtureIsStable() {
        val hex = TourSessionFixtures.handshakeFixtureHex()
        assertEquals(
            "474f4832020102050000000000000000000100112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000000001102000102030405060708090a0b0c0d0e0f|474f4832020102020000000000000000000200112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000000003102202122232425262728292a2b2c2d2e2fc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf|474f4832020102040000000000000000002b00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f00000000",
            hex,
        )
        val envelopes = hex.split("|").map { SessionEnvelope.decode(it.hexToByteArray()) }
        assertEquals(
            listOf(SessionMessageKind.AUTH_CHALLENGE, SessionMessageKind.WELCOME, SessionMessageKind.LEAVE),
            envelopes.map { it.kind },
        )
        assertEquals(
            listOf(TourSessionFixtures.guideId, TourSessionFixtures.guideId, TourSessionFixtures.guestId),
            envelopes.map { it.senderId },
        )
        assertEquals(listOf(1L, 2L, 43L), envelopes.map { it.sequence })
        val challenge = AuthChallengePayload.decode(envelopes[0].payload)
        assertEquals(SessionLane.CONTROL, challenge.requestedLane)
        assertArrayEquals(ByteArray(16) { it.toByte() }, challenge.challengeNonce)
        val welcome = WelcomePayload.decode(envelopes[1].payload)
        assertEquals(SessionLane.CONTROL, welcome.requestedLane)
        assertArrayEquals(ByteArray(16) { (0x20 + it).toByte() }, welcome.guideNonce)
        assertArrayEquals(ByteArray(32) { (0xc0 + it).toByte() }, welcome.credentialProof)
        assertEquals(0, envelopes[2].payload.size)
    }

    @Test
    fun realtimeAudioFrameSealsDeterministically() {
        val sealed = TourSessionFixtures.encryptedRealtimeFixture()
        assertEquals(
            "474f4832040001100000000000000000004d00112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000f1e2d3c4b5a69788796a5b4c3d2e1f00000003adb8e5ed09b1fad51b1b2510ba6717d8d7f6542479429e44ea0349ee37b6ca4c834475e6c0e328fd8a8d8a2b6af8e80b05390378434de32c1675e",
            sealed.encode().lowercaseHex(),
        )
        assertArrayEquals(sealed.encode(), TourSessionFixtures.encryptedRealtimeFixture().encode())
        val opened = SessionFrameOpener(TourSessionFixtures.fixtureCredential()).open(sealed)
        assertTrue(opened is SessionFrameOpenResult.Opened)
        val envelope = (opened as SessionFrameOpenResult.Opened).envelope
        assertEquals(SessionLane.REALTIME, envelope.lane)
        assertEquals(SessionMessageKind.AUDIO_FRAME, envelope.kind)
        assertEquals(77L, envelope.sequence)
        assertEquals(TourSessionFixtures.guideId, envelope.senderId)
        assertEquals(TourSessionFixtures.encodedAudioFixture(), EncodedAudioFramePayload.decode(envelope.payload))
    }

    @Test
    fun stateFixtureDescribesEveryControlAndAssetKind() {
        val stateDescription = listOf(
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=presentationSnapshot|sequence=9|stateVersion=7|deckID=12345678-90ab-cdef-1234-567890abcdef|slide=676174652d6c656674|visible=true|effectiveAtMilliseconds=123456",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=bearingSnapshot|sequence=10|stateVersion=8|reference=1|bearingMilliDegrees=271250|visible=true",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=targetSnapshot|sequence=11|stateVersion=9|targetID=abcdef01-2345-6789-abcd-ef0123456789|latitudeE7=371769000|longitudeE7=-35889000|label=4d61696e2047617465|visible=true",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=visualFocusSnapshot|sequence=12|stateVersion=10|mode=2",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=asset|kind=assetManifest|sequence=12|deckID=12345678-90ab-cdef-1234-567890abcdef|manifestVersion=3|assets=676174652d6c656674,000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f,2048,0,696d6167652f6a706567;676174652defbd9e,1212121212121212121212121212121212121212121212121212121212121212,256,0,696d6167652f6a706567;676174652df09f97ba,efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef,512,0,696d6167652f6a706567",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=asset|kind=tourPackManifest|sequence=13|packID=87654321-0fed-cba9-8765-43210fedcba9|manifestVersion=4|displayName=416c68616d627261|assets=616c68616d6272612d6d6170,2,cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd,4096,0,6170706c69636174696f6e2f766e642e706d74696c6573;676174652d6c656674,1,abababababababababababababababababababababababababababababababab,2048,1,696d6167652f6a706567;706c617a612defbd9e,1,1212121212121212121212121212121212121212121212121212121212121212,256,2,696d6167652f6a706567;706c617a612df09f97ba,1,efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef,512,2,696d6167652f6a706567",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=10213243-5465-7687-98a9-bacbdcedfe0f|lane=asset|kind=assetRequest|sequence=14|sha256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f|offset=1024",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=10213243-5465-7687-98a9-bacbdcedfe0f|lane=asset|kind=assetStatus|sequence=15|sha256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f|status=1|byteLength=2048|detail=",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=asset|kind=assetChunk|sequence=16|sha256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f|offset=1024|totalLength=2048|bytes=303132333435363738393a3b3c3d3e3f",
        ).joinToString("\n")
        assertEquals(stateDescription, TourSessionFixtures.describeEnvelopes(TourSessionFixtures.stateFixtureHex()))

        val handshakeDescription = listOf(
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=authChallenge|sequence=1|requestedLane=2|challengeNonce=000102030405060708090a0b0c0d0e0f",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=welcome|sequence=2|requestedLane=2|guideNonce=202122232425262728292a2b2c2d2e2f|credentialProof=c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=10213243-5465-7687-98a9-bacbdcedfe0f|lane=control|kind=leave|sequence=43|payloadBytes=0",
        ).joinToString("\n")
        assertEquals(handshakeDescription, TourSessionFixtures.describeEnvelopes(TourSessionFixtures.handshakeFixtureHex()))

        val audioDescription = "codec=1|sampleRate=16000|channelCount=1|frameDurationMilliseconds=20|bitRate=20000|codecSpecificData=|capturedAtNanoseconds=1000000000|expiresAtNanoseconds=1250000000|encodedBytes=f8fffe010203"
        assertEquals(
            audioDescription,
            TourSessionFixtures.describeAudioFrame(TourSessionFixtures.encodedAudioFixture().encode()),
        )

        val sealedDescription = TourSessionFixtures.describeSealed(TourSessionFixtures.encryptedRealtimeFixture().encode())
        assertTrue(
            sealedDescription.startsWith(
                "version=${SealedSessionEnvelope.MAJOR_VERSION}.${SealedSessionEnvelope.MINOR_VERSION}" +
                    "|stream=0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0|",
            ),
        )
        assertTrue(sealedDescription.endsWith("|lane=realtime|kind=audioFrame|sequence=77|audio=$audioDescription"))
    }

    @Test
    fun encodedAudioFrameAndCodecNegotiationAreDeterministic() {
        val fixture = TourSessionFixtures.encodedAudioFixture()
        assertEquals(
            "0100003e8001001400004e2000000000000000003b9aca00000000004a817c8000000006f8fffe010203",
            fixture.encode().lowercaseHex(),
        )
        assertEquals(EncodedAudioFramePayload.FIXED_HEADER_SIZE + fixture.encodedBytes.size, fixture.encode().size)
        assertEquals(fixture, EncodedAudioFramePayload.decode(fixture.encode()))

        val configurationWithCookie = SessionAudioCodecConfiguration(
            codec = SessionAudioCodec.AAC_LC,
            sampleRate = 16_000,
            channelCount = 1,
            frameDurationMilliseconds = 64,
            bitRate = 16_000,
            codecSpecificData = byteArrayOf(0x12, 0x10),
        )
        val withCookie = EncodedAudioFramePayload(
            configuration = configurationWithCookie,
            capturedAtNanoseconds = 10,
            expiresAtNanoseconds = 20,
            encodedBytes = byteArrayOf(0xAA.toByte()),
        )
        assertEquals(withCookie, EncodedAudioFramePayload.decode(withCookie.encode()))
        assertFalse(fixture.isExpired(fixture.expiresAtNanoseconds - 1))
        assertTrue(fixture.isExpired(fixture.expiresAtNanoseconds))

        val all = SessionCapability.entries.fold(0L) { value, capability -> value or capability.bit }
        assertEquals(SessionAudioCodec.OPUS, SessionAudioCodecNegotiation.preferredCodec(all, all))
        assertEquals(
            SessionAudioCodec.AAC_LC,
            SessionAudioCodecNegotiation.preferredCodec(
                SessionCapability.AAC_LC_ENCODER.bit,
                SessionCapability.AAC_LC_DECODER.bit,
            ),
        )
        assertThrows(EncodedAudioFrameException::class.java) {
            SessionAudioCodecNegotiation.preferredCodec(
                SessionCapability.OPUS_ENCODER.bit,
                SessionCapability.AAC_LC_DECODER.bit,
            )
        }
    }

    @Test
    fun realtimeAudioAccumulationAndJitterAreBounded() {
        val accumulator = PCMFrameAccumulator(frameByteCount = 4)
        assertTrue(accumulator.append(byteArrayOf(0, 1, 2)).isEmpty())
        val frames = accumulator.append(byteArrayOf(3, 4, 5, 6, 7, 8))
        assertEquals(2, frames.size)
        assertArrayEquals(byteArrayOf(0, 1, 2, 3), frames[0])
        assertArrayEquals(byteArrayOf(4, 5, 6, 7), frames[1])
        assertEquals(1, accumulator.bufferedByteCount)
        assertArrayEquals(
            byteArrayOf(8, 9, 10, 11),
            accumulator.append(byteArrayOf(9, 10, 11)).single(),
        )

        val payload = EncodedAudioFramePayload(
            configuration = TourSessionFixtures.encodedAudioFixture().configuration,
            capturedAtNanoseconds = 100,
            expiresAtNanoseconds = 1_000,
            encodedBytes = byteArrayOf(1),
        )
        val jitter = EncodedAudioJitterBuffer(targetFrameCount = 3, maximumFrameCount = 4)
        assertEquals(
            EncodedAudioFrameOfferResult.ACCEPTED,
            jitter.offer(SequencedEncodedAudioFrame(11, payload), nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioFrameOfferResult.ACCEPTED,
            jitter.offer(SequencedEncodedAudioFrame(10, payload), nowNanoseconds = 200),
        )
        assertEquals(EncodedAudioPlayoutDecision.Wait, jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(
            EncodedAudioFrameOfferResult.ACCEPTED,
            jitter.offer(SequencedEncodedAudioFrame(12, payload), nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioPlayoutDecision.Frame(SequencedEncodedAudioFrame(10, payload)),
            jitter.popForPlayout(nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioPlayoutDecision.Frame(SequencedEncodedAudioFrame(11, payload)),
            jitter.popForPlayout(nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioFrameOfferResult.DUPLICATE,
            jitter.offer(SequencedEncodedAudioFrame(10, payload), nowNanoseconds = 200),
        )

        val full = EncodedAudioJitterBuffer(targetFrameCount = 2, maximumFrameCount = 2)
        assertEquals(
            EncodedAudioFrameOfferResult.ACCEPTED,
            full.offer(SequencedEncodedAudioFrame(1, payload), nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioFrameOfferResult.ACCEPTED,
            full.offer(SequencedEncodedAudioFrame(2, payload), nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioFrameOfferResult.CAPACITY_EXCEEDED,
            full.offer(SequencedEncodedAudioFrame(3, payload), nowNanoseconds = 200),
        )
        assertEquals(
            EncodedAudioFrameOfferResult.EXPIRED,
            full.offer(SequencedEncodedAudioFrame(4, payload), nowNanoseconds = 1_100),
        )

        val skewed = EncodedAudioJitterBuffer(targetFrameCount = 1, maximumFrameCount = 2)
        assertEquals(
            EncodedAudioFrameOfferResult.ACCEPTED,
            skewed.offer(SequencedEncodedAudioFrame(1, payload), nowNanoseconds = 10_000),
        )
        assertEquals(
            EncodedAudioPlayoutDecision.Frame(SequencedEncodedAudioFrame(1, payload)),
            skewed.popForPlayout(nowNanoseconds = 10_899),
        )
        assertEquals(
            EncodedAudioFrameOfferResult.EXPIRED,
            skewed.offer(SequencedEncodedAudioFrame(2, payload), nowNanoseconds = 11_000),
        )
    }

    @Test
    fun clockedPlayoutConcealsGapsAndResyncs() {
        val payload = EncodedAudioFramePayload(
            configuration = TourSessionFixtures.encodedAudioFixture().configuration,
            capturedAtNanoseconds = 100,
            expiresAtNanoseconds = 1_000,
            encodedBytes = byteArrayOf(1),
        )
        fun frame(sequence: Long) = EncodedAudioPlayoutDecision.Frame(SequencedEncodedAudioFrame(sequence, payload))
        val jitter = EncodedAudioJitterBuffer(targetFrameCount = 2, maximumFrameCount = 4)
        // Every pop is at now=200 except the final pop at 2_000, which expires the buffered frame.
        assertEquals(EncodedAudioPlayoutDecision.Wait, jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(EncodedAudioFrameOfferResult.ACCEPTED, jitter.offer(SequencedEncodedAudioFrame(1, payload), 200))
        assertEquals(EncodedAudioPlayoutDecision.Wait, jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(EncodedAudioFrameOfferResult.ACCEPTED, jitter.offer(SequencedEncodedAudioFrame(2, payload), 200))
        assertEquals(frame(1), jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(frame(2), jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(EncodedAudioPlayoutDecision.Wait, jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(EncodedAudioFrameOfferResult.ACCEPTED, jitter.offer(SequencedEncodedAudioFrame(4, payload), 200))
        assertEquals(EncodedAudioPlayoutDecision.Conceal(3), jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(frame(4), jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(EncodedAudioFrameOfferResult.ACCEPTED, jitter.offer(SequencedEncodedAudioFrame(10, payload), 200))
        assertEquals(EncodedAudioFrameOfferResult.ACCEPTED, jitter.offer(SequencedEncodedAudioFrame(11, payload), 200))
        assertEquals(frame(10), jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(frame(11), jitter.popForPlayout(nowNanoseconds = 200))
        assertEquals(EncodedAudioFrameOfferResult.ACCEPTED, jitter.offer(SequencedEncodedAudioFrame(12, payload), 200))
        assertEquals(EncodedAudioPlayoutDecision.Wait, jitter.popForPlayout(nowNanoseconds = 2_000))
        assertEquals(0, jitter.bufferedFrameCount)

        assertEquals("w,w,f1,f2,w,c3,f4,f10,f11,w", TourSessionFixtures.simulatePlayout())
    }

    @Test
    fun messageKindsCannotEnterWrongLane() {
        assertThrows(SessionProtocolException::class.java) {
            SessionEnvelope(
                lane = SessionLane.CONTROL,
                kind = SessionMessageKind.AUDIO_FRAME,
                sequence = 1,
                sessionId = TourSessionFixtures.sessionId,
                senderId = TourSessionFixtures.guestId,
                payload = byteArrayOf(),
            )
        }
    }

    @Test
    fun truncatedPayloadFailsLoudly() {
        val encoded = TourSessionFixtures.helloEnvelope().encode().dropLast(1).toByteArray()
        val error = assertThrows(SessionProtocolException::class.java) {
            SessionEnvelope.decode(encoded)
        }
        assertEquals("payload length mismatch: expected 64, got 63", error.message)
    }

    @Test
    fun utf8HelloRoundtrips() {
        val source = HelloPayload(
            SessionRole.GUEST,
            ParticipantPlatform.IOS,
            7,
            "ضيف",
            SessionLane.ASSET,
            ByteArray(SessionAuthenticator.NONCE_SIZE) { 0x11 },
            ByteArray(SessionAuthenticator.PROOF_SIZE) { 0x22 },
        )
        val decoded = HelloPayload.decode(source.encode())
        assertEquals(source.role, decoded.role)
        assertEquals(source.platform, decoded.platform)
        assertEquals(source.capabilities, decoded.capabilities)
        assertEquals(source.displayName, decoded.displayName)
        assertEquals(source.requestedLane, decoded.requestedLane)
        assertArrayEquals(source.clientNonce, decoded.clientNonce)
        assertArrayEquals(source.credentialProof, decoded.credentialProof)
    }

    @Test
    fun authenticationProofsAreStableAndRejectAnotherTourCode() {
        assertEquals(
            "5f837f1767e9bddd9a65096b1b2f458f1329a4f1c9e9a4d09bb9f15f8225a86d|98950abd4bf6d1e9ef3ea546586c7d027797d5e379aab69f1b99c23067d90a8f",
            TourSessionFixtures.authenticationFixtureHex(),
        )
        val correct = SessionCredential.derive("23456-789 ab", TourSessionFixtures.sessionId)
        assertArrayEquals(TourSessionFixtures.fixtureCredential().key, correct.key)
        val wrong = SessionCredential.derive("23456789AC", TourSessionFixtures.sessionId)
        val challenge = ByteArray(16) { it.toByte() }
        val client = ByteArray(16) { (0x10 + it).toByte() }
        val expected = SessionAuthenticator.guestProof(
            correct,
            TourSessionFixtures.sessionId,
            TourSessionFixtures.guideId,
            TourSessionFixtures.guestId,
            SessionLane.CONTROL,
            challenge,
            client,
            SessionRole.GUEST,
            ParticipantPlatform.ANDROID,
            3,
            "Guest 7",
        )
        val invalid = SessionAuthenticator.guestProof(
            wrong,
            TourSessionFixtures.sessionId,
            TourSessionFixtures.guideId,
            TourSessionFixtures.guestId,
            SessionLane.CONTROL,
            challenge,
            client,
            SessionRole.GUEST,
            ParticipantPlatform.ANDROID,
            3,
            "Guest 7",
        )
        assertEquals(false, SessionAuthenticator.securelyMatches(expected, invalid))
        assertThrows(SessionSecurityException::class.java) {
            SessionCredential.derive("O1IL", TourSessionFixtures.sessionId)
        }
    }

    @Test
    fun credentialStretchIsAPbkdf2WireContract() {
        assertEquals(4, SealedSessionEnvelope.MAJOR_VERSION)
        assertEquals(600_000, SessionCredential.STRETCH_ITERATIONS)
        assertEquals("GetOverHere/GOH4/credential-salt/v1", SessionCredential.STRETCH_SALT_LABEL)
        assertEquals(32, SessionCredential.STRETCHED_KEY_SIZE)
        val fixtureSalt = "00112233445566778899aabbccddeeff4765744f766572486572652f474f48342f63726564656e7469616c2d73616c742f7631".hexToByteArray()
        assertEquals(
            "92ed1ff17b00d8ed95c29c42930eea012bf535f0375174f8c01b0caa46bef215",
            SessionCredential.stretch("23456789AB", fixtureSalt).lowercaseHex(),
        )
        assertEquals(
            "21ad5672cb5998d6c28ca6573e170ca605c0d71d22ae25ede7444c124ef4b1cf",
            TourSessionFixtures.fixtureCredential().key.lowercaseHex(),
        )
    }

    @Test
    fun authenticationChallengeAndWelcomeRoundtrip() {
        val challenge = AuthChallengePayload(SessionLane.ASSET, ByteArray(16) { it.toByte() })
        val decodedChallenge = AuthChallengePayload.decode(challenge.encode())
        assertEquals(challenge.requestedLane, decodedChallenge.requestedLane)
        assertArrayEquals(challenge.challengeNonce, decodedChallenge.challengeNonce)
        val welcome = WelcomePayload(
            SessionLane.ASSET,
            ByteArray(16) { (0x20 + it).toByte() },
            ByteArray(32) { 0xab.toByte() },
        )
        val decodedWelcome = WelcomePayload.decode(welcome.encode())
        assertEquals(welcome.requestedLane, decodedWelcome.requestedLane)
        assertArrayEquals(welcome.guideNonce, decodedWelcome.guideNonce)
        assertArrayEquals(welcome.credentialProof, decodedWelcome.credentialProof)
    }

    @Test
    fun wifiAwareAnnouncementHasStableCrossPlatformBytes() {
        val announcement = AwareSessionAnnouncement(
            TourSessionFixtures.sessionId,
            TourSessionFixtures.guideId,
            ParticipantPlatform.IOS,
            51_000,
            51_001,
            51_002,
            "Alhambra",
            "Ahmed",
        )
        val encoded = announcement.encode()
        assertEquals(
            "474f48410100112233445566778899aabbccddeeffffeeddccbbaa9988776655443322110001c738c739c73a0008416c68616d627261000541686d6564",
            encoded.lowercaseHex(),
        )
        assertEquals(announcement, AwareSessionAnnouncement.decode(encoded))
        assertThrows(IllegalArgumentException::class.java) {
            announcement.copy(realtimePort = 0)
        }
    }
}

class ParticipantRegistryTest {
    @Test
    fun reconnectReplacesOldConnectionWithoutIncrementingListeners() {
        val registry = ParticipantRegistry()
        registry.register(
            ParticipantSession(
                TourSessionFixtures.guestId,
                "old",
                "Guest 7",
                SessionRole.GUEST,
                ParticipantPlatform.ANDROID,
            ),
        )
        registry.register(
            ParticipantSession(
                TourSessionFixtures.guestId,
                "new",
                "Guest 7",
                SessionRole.GUEST,
                ParticipantPlatform.ANDROID,
            ),
        )

        assertEquals(1, registry.listenerCount)
        assertNull(registry.disconnect("old"))
        assertEquals(1, registry.listenerCount)
        assertEquals(TourSessionFixtures.guestId, registry.disconnect("new")?.participantId)
        assertEquals(0, registry.listenerCount)
    }

    @Test
    fun guideIsNotCountedAsListener() {
        val registry = ParticipantRegistry()
        registry.register(
            ParticipantSession(
                TourSessionFixtures.sessionId,
                "guide",
                "Guide",
                SessionRole.GUIDE,
                ParticipantPlatform.IOS,
            ),
        )
        assertEquals(0, registry.listenerCount)
    }

    @Test
    fun participantScaleAndChurn() {
        listOf(1, 8, 20, 50).forEach { count ->
            assertEquals(
                "peak=$count|reconnect=$count|staleDisconnect=$count|final=0",
                TourSessionFixtures.simulateParticipants(count),
            )
        }
    }

    @Test
    fun realtimeAuditDetectsLossDuplicateAndReorder() {
        assertEquals(
            "unique=5|duplicates=1|reordered=1|missing=2",
            RealtimeSequenceAudit.analyze(listOf(1, 2, 2, 5, 4, 7)).report,
        )
    }

    @Test
    fun recoverySimulationCoversLateJoinReconnectMissingAssetsAndTargetReplacement() {
        assertEquals(
            "lateSlide=gate-left|lateTarget=9|reconnect=1|staleTarget=9|replacementTarget=10|missing=1|readyAfterFetch=true",
            TourSessionFixtures.simulateRecovery(),
        )
    }

    @Test
    fun visualFocusIsAuthoritativeVersionedAndReconnectable() {
        assertEquals(
            "initial=slides:0|guide=map:1,pointer:2|guest=pointer:2|stale=pointer:2|late=pointer:2",
            TourSessionFixtures.simulateVisualFocus(),
        )
    }

    @Test
    fun presentationBearingTargetAndTourPackRoundtrip() {
        val presentation = PresentationSnapshotPayload(
            7,
            TourSessionFixtures.deckId,
            "gate-left",
            true,
            123_456,
        )
        assertEquals(presentation, PresentationSnapshotPayload.decode(presentation.encode()))

        val focus = VisualFocusSnapshotPayload(10, TourVisualMode.MAP)
        assertEquals(9, focus.encode().size)
        assertEquals(focus, VisualFocusSnapshotPayload.decode(focus.encode()))
        assertThrows(SessionProtocolException::class.java) {
            VisualFocusSnapshotPayload.decode(ByteArray(8) + 4)
        }

        val bearing = BearingSnapshotPayload(
            8,
            BearingReference.MAGNETIC,
            271_250,
            true,
        )
        assertEquals(14, bearing.encode().size)
        assertEquals(bearing, BearingSnapshotPayload.decode(bearing.encode()))

        val target = TargetSnapshotPayload(
            9,
            TourSessionFixtures.targetId,
            371_769_000,
            -35_889_000,
            "Main Gate",
            true,
        )
        assertEquals(target, TargetSnapshotPayload.decode(target.encode()))

        val asset = SlideAssetDescriptor(
            "gate-left",
            "ab".repeat(32),
            4,
            0,
            "image/jpeg",
        )
        val manifest = AssetManifestPayload(TourSessionFixtures.deckId, 3, listOf(asset))
        assertEquals(manifest, AssetManifestPayload.decode(manifest.encode()))

        val chunk = AssetChunkPayload(asset.sha256, 0, 4, byteArrayOf(1, 2, 3, 4))
        assertEquals(chunk, AssetChunkPayload.decode(chunk.encode()))

        val request = AssetRequestPayload(asset.sha256, 2)
        assertEquals(request, AssetRequestPayload.decode(request.encode()))
        val status = AssetStatusPayload(asset.sha256, AssetTransferStatus.READY, asset.byteLength, "")
        assertEquals(status, AssetStatusPayload.decode(status.encode()))

        val tourAsset = TourAssetDescriptor(
            asset.slideID,
            TourAssetKind.SLIDE,
            asset.sha256,
            asset.byteLength,
            asset.order,
            asset.mimeType,
        )
        val tourPack = TourPackManifestPayload(
            TourSessionFixtures.packId,
            4,
            "Alhambra",
            listOf(tourAsset),
        )
        assertEquals(tourPack, TourPackManifestPayload.decode(tourPack.encode()))
    }

    @Test
    fun targetCoordinatesRejectInvalidGeographicBoundaries() {
        assertThrows(SessionProtocolException::class.java) {
            TargetSnapshotPayload(1, TourSessionFixtures.targetId, 900_000_001, 0, "", true)
        }
        assertThrows(SessionProtocolException::class.java) {
            TargetSnapshotPayload(1, TourSessionFixtures.targetId, 0, -1_800_000_001, "", true)
        }
    }

    @Test
    fun targetSnapshotSurvives100DeterministicGeographicRoundtrips() {
        val random = Random(0x474f4832)
        repeat(100) { index ->
            val payload = TargetSnapshotPayload(
                index.toLong(),
                TourSessionFixtures.targetId,
                random.nextLong(-900_000_000L, 900_000_001L).toInt(),
                random.nextLong(-1_800_000_000L, 1_800_000_001L).toInt(),
                "Target $index",
                index % 2 == 0,
            )
            assertEquals(payload, TargetSnapshotPayload.decode(payload.encode()))
        }
    }

    @Test
    fun targetGuidanceIsCalculatedOnlyFromLocalInputs() {
        assertEquals(0.0, TargetGuidance.distanceMeters(0, 0, 0, 0), 0.0)
        assertEquals(90.0, TargetGuidance.initialBearingDegrees(0, 0, 0, 10_000_000), 0.000_001)
        assertEquals(20.0, TargetGuidance.relativeArrowDegrees(10.0, 350.0), 0.000_001)
        assertEquals(
            false,
            TargetGuidance.distanceMeters(0, 0, 0, 1_800_000_000).isNaN(),
        )
    }

    @Test
    fun hybridRoutesPreferLanAndFallBackToWiFiAware() {
        assertEquals(
            listOf(SessionTransportRoute.LOCAL_LAN, SessionTransportRoute.WIFI_AWARE),
            SessionRouteAvailability(true, true).orderedRoutes,
        )
        assertEquals(
            listOf(SessionTransportRoute.WIFI_AWARE),
            SessionRouteAvailability(false, true).orderedRoutes,
        )
        assertEquals(emptyList<SessionTransportRoute>(), SessionRouteAvailability(false, false).orderedRoutes)
    }

    @Test
    fun oneRouteLeaseOwnsEverySessionLane() {
        val lease = SessionRouteLease()
        assertEquals(true, lease.select(SessionTransportRoute.LOCAL_LAN))
        assertEquals(true, lease.select(SessionTransportRoute.LOCAL_LAN))
        assertEquals(false, lease.select(SessionTransportRoute.WIFI_AWARE))
        lease.reset()
        assertEquals(true, lease.select(SessionTransportRoute.WIFI_AWARE))
    }
}
