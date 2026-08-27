package com.aessam.toursession

import java.util.UUID

object TourSessionFixtures {
    val sessionId: UUID = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
    val guestId: UUID = UUID.fromString("10213243-5465-7687-98a9-bacbdcedfe0f")
    val guideId: UUID = UUID.fromString("ffeeddcc-bbaa-9988-7766-554433221100")
    val deckId: UUID = UUID.fromString("12345678-90ab-cdef-1234-567890abcdef")
    val targetId: UUID = UUID.fromString("abcdef01-2345-6789-abcd-ef0123456789")
    val packId: UUID = UUID.fromString("87654321-0fed-cba9-8765-43210fedcba9")
    val streamId: UUID = UUID.fromString("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")

    fun helloEnvelope(): SessionEnvelope = SessionEnvelope(
        lane = SessionLane.CONTROL,
        kind = SessionMessageKind.HELLO,
        sequence = 42,
        sessionId = sessionId,
        senderId = guestId,
        payload = HelloPayload(
            role = SessionRole.GUEST,
            platform = ParticipantPlatform.ANDROID,
            capabilities = 3,
            displayName = "Guest 7",
            requestedLane = SessionLane.CONTROL,
            clientNonce = ByteArray(16) { it.toByte() },
            credentialProof = ByteArray(32) { (0xa0 + it).toByte() },
        ).encode(),
    )

    fun describeHello(encoded: ByteArray): String {
        val envelope = SessionEnvelope.decode(encoded)
        if (envelope.kind != SessionMessageKind.HELLO) {
            throw SessionProtocolException("expected hello, got ${envelope.kind.wireName}")
        }
        val hello = HelloPayload.decode(envelope.payload)
        return listOf(
            "session=${envelope.sessionId.toString().lowercase()}",
            "sender=${envelope.senderId.toString().lowercase()}",
            "lane=${envelope.lane.wireName}",
            "kind=${envelope.kind.wireName}",
            "sequence=${envelope.sequence}",
            "role=${hello.role.wireName}",
            "platform=${hello.platform.wireName}",
            "name=${hello.displayName}",
            "capabilities=${hello.capabilities}",
            "requestedLane=${hello.requestedLane.wireName}",
        ).joinToString("|")
    }

    fun encryptedHelloFixture(): SealedSessionEnvelope =
        SessionFrameSealer(fixtureCredential()).seal(helloEnvelope(), streamId)

    fun describeEncryptedHello(encoded: ByteArray): String {
        val sealed = SealedSessionEnvelope.decode(encoded)
        val opened = SessionFrameOpener(fixtureCredential()).open(sealed)
        check(opened is SessionFrameOpenResult.Opened) { "a fresh fixture cannot be a duplicate" }
        val envelope = opened.envelope
        if (envelope.kind != SessionMessageKind.HELLO) {
            throw SessionProtocolException("expected hello, got ${envelope.kind.wireName}")
        }
        val hello = HelloPayload.decode(envelope.payload)
        return listOf(
            "version=${SealedSessionEnvelope.MAJOR_VERSION}.${SealedSessionEnvelope.MINOR_VERSION}",
            "session=${envelope.sessionId.toString().lowercase()}",
            "sender=${envelope.senderId.toString().lowercase()}",
            "stream=${sealed.streamId.toString().lowercase()}",
            "lane=${envelope.lane.wireName}",
            "kind=${envelope.kind.wireName}",
            "sequence=${envelope.sequence}",
            "role=${hello.role.wireName}",
            "platform=${hello.platform.wireName}",
            "name=${hello.displayName}",
            "capabilities=${hello.capabilities}",
            "requestedLane=${hello.requestedLane.wireName}",
        ).joinToString("|")
    }

    fun encodedAudioFixture(): EncodedAudioFramePayload = EncodedAudioFramePayload(
        SessionAudioCodecConfiguration(
            SessionAudioCodec.OPUS,
            16_000,
            1,
            20,
            20_000,
        ),
        1_000_000_000,
        1_250_000_000,
        byteArrayOf(0xf8.toByte(), 0xff.toByte(), 0xfe.toByte(), 1, 2, 3),
    )

    fun simulateParticipants(count: Int): String {
        require(count >= 0)
        val registry = ParticipantRegistry()
        val initialConnections = mutableListOf<String>()

        repeat(count) { index ->
            val participant = ParticipantSession(
                participantId = deterministicUuid(index),
                connectionId = "initial-$index",
                displayName = "Guest $index",
                role = SessionRole.GUEST,
                platform = if (index % 2 == 0) ParticipantPlatform.IOS else ParticipantPlatform.ANDROID,
            )
            registry.register(participant)
            initialConnections += participant.connectionId
        }
        val peak = registry.listenerCount

        repeat(count) { index ->
            registry.register(
                ParticipantSession(
                    participantId = deterministicUuid(index),
                    connectionId = "replacement-$index",
                    displayName = "Guest $index",
                    role = SessionRole.GUEST,
                    platform = if (index % 2 == 0) ParticipantPlatform.IOS else ParticipantPlatform.ANDROID,
                ),
            )
        }
        val afterReconnect = registry.listenerCount

        initialConnections.forEach(registry::disconnect)
        val afterStaleDisconnect = registry.listenerCount

        repeat(count) { index -> registry.disconnect("replacement-$index") }
        return "peak=$peak|reconnect=$afterReconnect|staleDisconnect=$afterStaleDisconnect|final=${registry.listenerCount}"
    }

    fun stateFixtureHex(): String {
        val presentation = PresentationSnapshotPayload(
            stateVersion = 7,
            deckID = deckId,
            currentSlideID = "gate-left",
            isVisible = true,
            effectiveAtMilliseconds = 123_456,
        )
        val presentationEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.PRESENTATION_SNAPSHOT,
            sequence = 9,
            sessionId = sessionId,
            senderId = guideId,
            payload = presentation.encode(),
        )
        val bearing = BearingSnapshotPayload(
            stateVersion = 8,
            reference = BearingReference.MAGNETIC,
            bearingMilliDegrees = 271_250,
            isVisible = true,
        )
        val bearingEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.BEARING_SNAPSHOT,
            sequence = 10,
            sessionId = sessionId,
            senderId = guideId,
            payload = bearing.encode(),
        )
        val target = TargetSnapshotPayload(
            stateVersion = 9,
            targetID = targetId,
            latitudeE7 = 371_769_000,
            longitudeE7 = -35_889_000,
            label = "Main Gate",
            isVisible = true,
        )
        val targetEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.TARGET_SNAPSHOT,
            sequence = 11,
            sessionId = sessionId,
            senderId = guideId,
            payload = target.encode(),
        )
        val visualFocus = VisualFocusSnapshotPayload(10, TourVisualMode.MAP)
        val visualFocusEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.VISUAL_FOCUS_SNAPSHOT,
            sequence = 12,
            sessionId = sessionId,
            senderId = guideId,
            payload = visualFocus.encode(),
        )
        val hash = (0 until 32).joinToString("") { "%02x".format(it) }
        val asset = SlideAssetDescriptor("gate-left", hash, 2048, 0, "image/jpeg")
        val manifest = AssetManifestPayload(deckId, 3, listOf(asset))
        val manifestEnvelope = SessionEnvelope(
            lane = SessionLane.ASSET,
            kind = SessionMessageKind.ASSET_MANIFEST,
            sequence = 12,
            sessionId = sessionId,
            senderId = guideId,
            payload = manifest.encode(),
        )
        val mapAsset = TourAssetDescriptor(
            "alhambra-map",
            TourAssetKind.MAP_ARCHIVE,
            "cd".repeat(32),
            4096,
            0,
            "application/vnd.pmtiles",
        )
        val slideAsset = TourAssetDescriptor(
            "gate-left",
            TourAssetKind.SLIDE,
            "ab".repeat(32),
            2048,
            1,
            "image/jpeg",
        )
        val tourPack = TourPackManifestPayload(packId, 4, "Alhambra", listOf(slideAsset, mapAsset))
        val tourPackEnvelope = SessionEnvelope(
            lane = SessionLane.ASSET,
            kind = SessionMessageKind.TOUR_PACK_MANIFEST,
            sequence = 13,
            sessionId = sessionId,
            senderId = guideId,
            payload = tourPack.encode(),
        )
        val request = AssetRequestPayload(asset.sha256, 1024)
        val requestEnvelope = SessionEnvelope(
            lane = SessionLane.ASSET,
            kind = SessionMessageKind.ASSET_REQUEST,
            sequence = 14,
            sessionId = sessionId,
            senderId = guestId,
            payload = request.encode(),
        )
        val status = AssetStatusPayload(asset.sha256, AssetTransferStatus.READY, asset.byteLength, "")
        val statusEnvelope = SessionEnvelope(
            lane = SessionLane.ASSET,
            kind = SessionMessageKind.ASSET_STATUS,
            sequence = 15,
            sessionId = sessionId,
            senderId = guestId,
            payload = status.encode(),
        )
        return listOf(
            presentationEnvelope.encode().lowercaseHex(),
            bearingEnvelope.encode().lowercaseHex(),
            targetEnvelope.encode().lowercaseHex(),
            visualFocusEnvelope.encode().lowercaseHex(),
            manifestEnvelope.encode().lowercaseHex(),
            tourPackEnvelope.encode().lowercaseHex(),
            requestEnvelope.encode().lowercaseHex(),
            statusEnvelope.encode().lowercaseHex(),
        ).joinToString("|")
    }

    fun authenticationFixtureHex(): String {
        val credential = SessionCredential.derive("23456789AB", sessionId)
        val challengeNonce = ByteArray(16) { it.toByte() }
        val clientNonce = ByteArray(16) { (0x10 + it).toByte() }
        val guideNonce = ByteArray(16) { (0x20 + it).toByte() }
        val guestProof = SessionAuthenticator.guestProof(
            credential,
            sessionId,
            guideId,
            guestId,
            SessionLane.CONTROL,
            challengeNonce,
            clientNonce,
            SessionRole.GUEST,
            ParticipantPlatform.ANDROID,
            3,
            "Guest 7",
        )
        val guideProof = SessionAuthenticator.guideProof(
            credential,
            sessionId,
            guideId,
            guestId,
            SessionLane.CONTROL,
            challengeNonce,
            clientNonce,
            guideNonce,
        )
        return "${guestProof.lowercaseHex()}|${guideProof.lowercaseHex()}"
    }

    fun fixtureCredential(): SessionCredential = SessionCredential.derive("23456789AB", sessionId)

    fun simulateRecovery(): String {
        val guidePresentation = PresentationSnapshotPayload(
            7,
            deckId,
            "gate-left",
            true,
            123_456,
        )
        val guideTarget = TargetSnapshotPayload(
            9,
            targetId,
            371_769_000,
            -35_889_000,
            "Main Gate",
            true,
        )

        val lateJoinPresentation = PresentationSnapshotPayload.decode(guidePresentation.encode())
        var guestTarget = TargetSnapshotPayload.decode(guideTarget.encode())
        val lateJoinTargetVersion = guestTarget.stateVersion

        val staleTarget = TargetSnapshotPayload(8, targetId, 0, 0, "Stale", false)
        if (staleTarget.stateVersion > guestTarget.stateVersion) guestTarget = staleTarget
        val versionAfterStaleTarget = guestTarget.stateVersion

        val replacementTarget = TargetSnapshotPayload(
            10,
            targetId,
            371_761_284,
            -35_881_412,
            "Replacement",
            true,
        )
        if (replacementTarget.stateVersion > guestTarget.stateVersion) guestTarget = replacementTarget

        val mapAsset = TourAssetDescriptor(
            "alhambra-map",
            TourAssetKind.MAP_ARCHIVE,
            "cd".repeat(32),
            4_096,
            0,
            "application/vnd.pmtiles",
        )
        val slideAsset = TourAssetDescriptor(
            "gate-left",
            TourAssetKind.SLIDE,
            "ab".repeat(32),
            2_048,
            1,
            "image/jpeg",
        )
        val manifest = TourPackManifestPayload(packId, 4, "Alhambra", listOf(slideAsset, mapAsset))
        val readyHashes = mutableSetOf(mapAsset.sha256)
        val missingHashes = manifest.assets.map { it.sha256 }.filterNot(readyHashes::contains)
        readyHashes += missingHashes
        val readyAfterFetch = manifest.assets.all { readyHashes.contains(it.sha256) }

        val registry = ParticipantRegistry()
        registry.register(
            ParticipantSession(guestId, "initial", "Guest 7", SessionRole.GUEST, ParticipantPlatform.ANDROID),
        )
        registry.register(
            ParticipantSession(guestId, "replacement", "Guest 7", SessionRole.GUEST, ParticipantPlatform.ANDROID),
        )
        registry.disconnect("initial")

        return listOf(
            "lateSlide=${lateJoinPresentation.currentSlideID ?: "none"}",
            "lateTarget=$lateJoinTargetVersion",
            "reconnect=${registry.listenerCount}",
            "staleTarget=$versionAfterStaleTarget",
            "replacementTarget=${guestTarget.stateVersion}",
            "missing=${missingHashes.size}",
            "readyAfterFetch=$readyAfterFetch",
        ).joinToString("|")
    }

    fun simulateVisualFocus(): String {
        val initial = VisualFocusSnapshotPayload(0, TourVisualMode.SLIDES)
        val map = VisualFocusSnapshotPayload(1, TourVisualMode.MAP)
        val pointer = VisualFocusSnapshotPayload(2, TourVisualMode.POINTER)
        var guest = initial
        listOf(map, pointer).forEach { incoming ->
            if (incoming.stateVersion > guest.stateVersion) guest = incoming
        }
        val beforeStale = guest
        if (map.stateVersion > guest.stateVersion) guest = map
        val late = pointer
        return listOf(
            "initial=${initial.mode.name.lowercase()}:${initial.stateVersion}",
            "guide=${map.mode.name.lowercase()}:${map.stateVersion},${pointer.mode.name.lowercase()}:${pointer.stateVersion}",
            "guest=${beforeStale.mode.name.lowercase()}:${beforeStale.stateVersion}",
            "stale=${guest.mode.name.lowercase()}:${guest.stateVersion}",
            "late=${late.mode.name.lowercase()}:${late.stateVersion}",
        ).joinToString("|")
    }

    fun deterministicUuid(index: Int): UUID {
        val suffix = index.toLong().toString(16).padStart(12, '0')
        return UUID.fromString("aaaaaaaa-bbbb-cccc-dddd-$suffix")
    }
}
