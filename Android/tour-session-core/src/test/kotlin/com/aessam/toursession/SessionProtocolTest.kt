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
            "474f4832030002010000000000000000002a00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f0f1e2d3c4b5a69788796a5b4c3d2e1f000000050c7f03f42d9429524530ad6b2fdb72701e968b7d8c8b1f471366936db8c9e278bbea83db185892b7bfa27420165562877df907c7b735db72a8949fc7eb4fa46c3014b980fc13031a2c526ef32871ef1ad",
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
    fun encryptedProtocolRejectsLegacyMajorExplicitly() {
        val bytes = TourSessionFixtures.encryptedHelloFixture().encode().also {
            it[4] = SessionEnvelope.MAJOR_VERSION.toByte()
        }
        val error = assertThrows(UnsupportedSessionVersionException::class.java) {
            SealedSessionEnvelope.decode(bytes)
        }
        assertEquals(SessionEnvelope.MAJOR_VERSION, error.receivedMajorVersion)
        assertEquals(SealedSessionEnvelope.MAJOR_VERSION, error.supportedMajorVersion)
    }

    @Test
    fun encodedAudioFrameAndCodecNegotiationAreDeterministic() {
        val fixture = TourSessionFixtures.encodedAudioFixture()
        assertEquals(
            "0100003e8001001400004e20000000003b9aca00000000004a817c8000000006f8fffe010203",
            fixture.encode().lowercaseHex(),
        )
        assertEquals(EncodedAudioFramePayload.FIXED_HEADER_SIZE + fixture.encodedBytes.size, fixture.encode().size)
        assertEquals(fixture, EncodedAudioFramePayload.decode(fixture.encode()))
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
            "ae79db230a7910d38a2c941753c3ef29f0e0f74a7879cb5a04d1b450d7a2fb05|f304c62c6966c68cb380753be969776af76fee332070a59a3bf471d159b6b19b",
            TourSessionFixtures.authenticationFixtureHex(),
        )
        val correct = SessionCredential.derive("23456-789 ab", TourSessionFixtures.sessionId)
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
