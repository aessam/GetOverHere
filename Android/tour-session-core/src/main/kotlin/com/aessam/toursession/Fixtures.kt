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

    /**
     * Describes one or more `|`-separated plaintext envelopes, one line per envelope. The
     * output is the cross-language decode contract: payload enums as decimal raw values,
     * UUIDs lowercased, bytes and free-form strings as lowercase UTF-8 hex (DSCN-21).
     */
    fun describeEnvelopes(hexList: String): String =
        hexList.split("|").joinToString("\n") { describe(SessionEnvelope.decode(it.hexToByteArray())) }

    fun describeAudioFrame(encoded: ByteArray): String {
        val frame = EncodedAudioFramePayload.decode(encoded)
        return listOf(
            "codec=${frame.configuration.codec.rawValue}",
            "sampleRate=${frame.configuration.sampleRate}",
            "channelCount=${frame.configuration.channelCount}",
            "frameDurationMilliseconds=${frame.configuration.frameDurationMilliseconds}",
            "bitRate=${frame.configuration.bitRate}",
            "codecSpecificData=${frame.configuration.codecSpecificData.lowercaseHex()}",
            "capturedAtNanoseconds=${frame.capturedAtNanoseconds}",
            "expiresAtNanoseconds=${frame.expiresAtNanoseconds}",
            "encodedBytes=${frame.encodedBytes.lowercaseHex()}",
        ).joinToString("|")
    }

    private fun text(value: String): String = value.toByteArray(Charsets.UTF_8).lowercaseHex()

    private fun describe(envelope: SessionEnvelope): String {
        val fields = mutableListOf(
            "session=${envelope.sessionId.toString().lowercase()}",
            "sender=${envelope.senderId.toString().lowercase()}",
            "lane=${envelope.lane.wireName}",
            "kind=${envelope.kind.wireName}",
            "sequence=${envelope.sequence}",
        )
        when (envelope.kind) {
            SessionMessageKind.HELLO -> {
                val hello = HelloPayload.decode(envelope.payload)
                fields += listOf(
                    "role=${hello.role.rawValue}",
                    "platform=${hello.platform.rawValue}",
                    "name=${text(hello.displayName)}",
                    "capabilities=${hello.capabilities}",
                    "requestedLane=${hello.requestedLane.rawValue}",
                )
            }
            SessionMessageKind.AUTH_CHALLENGE -> {
                val challenge = AuthChallengePayload.decode(envelope.payload)
                fields += listOf(
                    "requestedLane=${challenge.requestedLane.rawValue}",
                    "challengeNonce=${challenge.challengeNonce.lowercaseHex()}",
                )
            }
            SessionMessageKind.WELCOME -> {
                val welcome = WelcomePayload.decode(envelope.payload)
                fields += listOf(
                    "requestedLane=${welcome.requestedLane.rawValue}",
                    "guideNonce=${welcome.guideNonce.lowercaseHex()}",
                    "credentialProof=${welcome.credentialProof.lowercaseHex()}",
                )
            }
            SessionMessageKind.HEARTBEAT, SessionMessageKind.LEAVE -> {
                fields += "payloadBytes=${envelope.payload.size}"
            }
            SessionMessageKind.PRESENTATION_SNAPSHOT -> {
                val presentation = PresentationSnapshotPayload.decode(envelope.payload)
                fields += listOf(
                    "stateVersion=${presentation.stateVersion}",
                    "deckID=${presentation.deckID.toString().lowercase()}",
                    "slide=${text(presentation.currentSlideID ?: "")}",
                    "visible=${presentation.isVisible}",
                    "effectiveAtMilliseconds=${presentation.effectiveAtMilliseconds}",
                )
            }
            SessionMessageKind.BEARING_SNAPSHOT -> {
                val bearing = BearingSnapshotPayload.decode(envelope.payload)
                fields += listOf(
                    "stateVersion=${bearing.stateVersion}",
                    "reference=${bearing.reference.rawValue}",
                    "bearingMilliDegrees=${bearing.bearingMilliDegrees}",
                    "visible=${bearing.isVisible}",
                )
            }
            SessionMessageKind.TARGET_SNAPSHOT -> {
                val target = TargetSnapshotPayload.decode(envelope.payload)
                fields += listOf(
                    "stateVersion=${target.stateVersion}",
                    "targetID=${target.targetID.toString().lowercase()}",
                    "latitudeE7=${target.latitudeE7}",
                    "longitudeE7=${target.longitudeE7}",
                    "label=${text(target.label)}",
                    "visible=${target.isVisible}",
                )
            }
            SessionMessageKind.AUDIO_STATUS -> {
                val status = AudioReadinessPayload.decode(envelope.payload)
                fields += listOf("status=${status.status.rawValue}", "revision=${status.revision}")
            }
            SessionMessageKind.VISUAL_FOCUS_SNAPSHOT -> {
                val focus = VisualFocusSnapshotPayload.decode(envelope.payload)
                fields += listOf("stateVersion=${focus.stateVersion}", "mode=${focus.mode.rawValue}")
            }
            SessionMessageKind.ASSET_MANIFEST -> {
                val manifest = AssetManifestPayload.decode(envelope.payload)
                val assets = manifest.assets.joinToString(";") {
                    "${text(it.slideID)},${it.sha256},${it.byteLength},${it.order},${text(it.mimeType)}"
                }
                fields += listOf(
                    "deckID=${manifest.deckID.toString().lowercase()}",
                    "manifestVersion=${manifest.manifestVersion}",
                    "assets=$assets",
                )
            }
            SessionMessageKind.TOUR_PACK_MANIFEST -> {
                val manifest = TourPackManifestPayload.decode(envelope.payload)
                val assets = manifest.assets.joinToString(";") {
                    "${text(it.assetID)},${it.kind.rawValue},${it.sha256},${it.byteLength},${it.order},${text(it.mimeType)}"
                }
                fields += listOf(
                    "packID=${manifest.packID.toString().lowercase()}",
                    "manifestVersion=${manifest.manifestVersion}",
                    "displayName=${text(manifest.displayName)}",
                    "assets=$assets",
                )
            }
            SessionMessageKind.ASSET_CHUNK -> {
                val chunk = AssetChunkPayload.decode(envelope.payload)
                fields += listOf(
                    "sha256=${chunk.sha256}",
                    "offset=${chunk.offset}",
                    "totalLength=${chunk.totalLength}",
                    "bytes=${chunk.bytes.lowercaseHex()}",
                )
            }
            SessionMessageKind.ASSET_REQUEST -> {
                val request = AssetRequestPayload.decode(envelope.payload)
                fields += listOf("sha256=${request.sha256}", "offset=${request.offset}")
            }
            SessionMessageKind.ASSET_STATUS -> {
                val status = AssetStatusPayload.decode(envelope.payload)
                fields += listOf(
                    "sha256=${status.sha256}",
                    "status=${status.status.rawValue}",
                    "byteLength=${status.byteLength}",
                    "detail=${text(status.detail)}",
                )
            }
            SessionMessageKind.AUDIO_FRAME -> {
                fields += "audio=${describeAudioFrame(envelope.payload)}"
            }
        }
        return fields.joinToString("|")
    }

    fun encryptedHelloFixture(): SealedSessionEnvelope =
        SessionFrameSealer(fixtureCredential()).seal(helloEnvelope(), streamId)

    /** Opens one sealed envelope with the fixture credential and describes it. */
    fun describeSealed(encoded: ByteArray): String {
        val sealed = SealedSessionEnvelope.decode(encoded)
        val opened = SessionFrameOpener(fixtureCredential()).open(sealed)
        check(opened is SessionFrameOpenResult.Opened) { "a fresh fixture cannot be a duplicate" }
        return "version=${SealedSessionEnvelope.MAJOR_VERSION}.${sealed.minorVersion}" +
            "|stream=${sealed.streamId.toString().lowercase()}|" +
            describe(opened.envelope)
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
        // Two more slides share order 0 so the fixture pins the UTF-8 tie-break (DSCN-7):
        // U+FF5E (ef bd 9e) precedes U+1F5FA (f0 9f 97 ba) although UTF-16 orders them the other way.
        val astralSlide = SlideAssetDescriptor("gate-\uD83D\uDDFA", "ef".repeat(32), 512, 0, "image/jpeg")
        val fullwidthSlide = SlideAssetDescriptor("gate-\uFF5E", "12".repeat(32), 256, 0, "image/jpeg")
        val manifest = AssetManifestPayload(deckId, 3, listOf(astralSlide, asset, fullwidthSlide))
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
        val astralAsset = TourAssetDescriptor(
            "plaza-\uD83D\uDDFA",
            TourAssetKind.SLIDE,
            "ef".repeat(32),
            512,
            2,
            "image/jpeg",
        )
        val fullwidthAsset = TourAssetDescriptor(
            "plaza-\uFF5E",
            TourAssetKind.SLIDE,
            "12".repeat(32),
            256,
            2,
            "image/jpeg",
        )
        val tourPack = TourPackManifestPayload(
            packId,
            4,
            "Alhambra",
            listOf(slideAsset, astralAsset, mapAsset, fullwidthAsset),
        )
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
        val chunk = AssetChunkPayload(asset.sha256, 1024, asset.byteLength, ByteArray(16) { (0x30 + it).toByte() })
        val chunkEnvelope = SessionEnvelope(
            lane = SessionLane.ASSET,
            kind = SessionMessageKind.ASSET_CHUNK,
            sequence = 16,
            sessionId = sessionId,
            senderId = guideId,
            payload = chunk.encode(),
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
            chunkEnvelope.encode().lowercaseHex(),
        ).joinToString("|")
    }

    /**
     * Plaintext authChallenge, welcome, and leave envelopes as they appear before and after
     * admission on every lane. The leave payload is empty, matching production.
     */
    fun handshakeFixtureHex(): String {
        val challengeEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.AUTH_CHALLENGE,
            sequence = 1,
            sessionId = sessionId,
            senderId = guideId,
            payload = AuthChallengePayload(SessionLane.CONTROL, ByteArray(16) { it.toByte() }).encode(),
        )
        val welcomeEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.WELCOME,
            sequence = 2,
            sessionId = sessionId,
            senderId = guideId,
            payload = WelcomePayload(
                SessionLane.CONTROL,
                ByteArray(16) { (0x20 + it).toByte() },
                ByteArray(32) { (0xc0 + it).toByte() },
            ).encode(),
        )
        val leaveEnvelope = SessionEnvelope(
            lane = SessionLane.CONTROL,
            kind = SessionMessageKind.LEAVE,
            sequence = 43,
            sessionId = sessionId,
            senderId = guestId,
            payload = byteArrayOf(),
        )
        return listOf(
            challengeEnvelope.encode().lowercaseHex(),
            welcomeEnvelope.encode().lowercaseHex(),
            leaveEnvelope.encode().lowercaseHex(),
        ).joinToString("|")
    }

    fun realtimeAudioEnvelope(): SessionEnvelope = SessionEnvelope(
        lane = SessionLane.REALTIME,
        kind = SessionMessageKind.AUDIO_FRAME,
        sequence = 77,
        sessionId = sessionId,
        senderId = guideId,
        payload = encodedAudioFixture().encode(),
    )

    /** The realtime audioFrame envelope sealed exactly as it travels on the wire. */
    fun encryptedRealtimeFixture(): SealedSessionEnvelope =
        SessionFrameSealer(fixtureCredential()).seal(realtimeAudioEnvelope(), streamId)

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

    /**
     * Deterministic playout-decision script shared with the Swift core (ADR-045). Every pop is
     * at now=200 except the final pop at 2_000, which expires the buffered frame 12.
     * Tokens: `w` wait, `f<seq>` frame, `c<seq>` conceal. Expected: `w,w,f1,f2,w,c3,f4,f10,f11,w`.
     */
    fun simulatePlayout(): String {
        val payload = EncodedAudioFramePayload(
            configuration = encodedAudioFixture().configuration,
            capturedAtNanoseconds = 100,
            expiresAtNanoseconds = 1_000,
            encodedBytes = byteArrayOf(1),
        )
        val jitter = EncodedAudioJitterBuffer(targetFrameCount = 2, maximumFrameCount = 4)
        val tokens = mutableListOf<String>()
        fun pop(now: Long) {
            tokens += when (val decision = jitter.popForPlayout(now)) {
                EncodedAudioPlayoutDecision.Wait -> "w"
                is EncodedAudioPlayoutDecision.Frame -> "f${decision.frame.sequence}"
                is EncodedAudioPlayoutDecision.Conceal -> "c${decision.missingSequence}"
            }
        }
        fun offer(sequence: Long) {
            jitter.offer(SequencedEncodedAudioFrame(sequence, payload), 200)
        }
        pop(200)
        offer(1); pop(200)
        offer(2); pop(200); pop(200); pop(200)
        offer(4); pop(200); pop(200)
        offer(10); offer(11); pop(200); pop(200)
        offer(12); pop(2_000)
        return tokens.joinToString(",")
    }

    fun deterministicUuid(index: Int): UUID {
        val suffix = index.toLong().toString(16).padStart(12, '0')
        return UUID.fromString("aaaaaaaa-bbbb-cccc-dddd-$suffix")
    }
}
