import Foundation
import Testing
@testable import TourSessionCore

@Suite("GOH2 session protocol")
struct SessionProtocolTests {
    @Test("Golden hello frame is stable")
    func goldenHelloFrame() throws {
        let encoded = try TourSessionFixtures.helloEnvelope().encode()
        #expect(encoded.lowercaseHex == "474f4832020102010000000000000000002a00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f0000004002020000000300074775657374203702000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
        #expect(try SessionEnvelope.decode(encoded) == TourSessionFixtures.helloEnvelope())
    }

    @Test("Encrypted frame is route-independent, authenticated, and replay-detectable")
    func encryptedFrameContract() throws {
        let credential = try TourSessionFixtures.fixtureCredential()
        let sealer = SessionFrameSealer(credential: credential)
        let logical = try TourSessionFixtures.helloEnvelope()
        let first = try sealer.seal(logical, streamID: TourSessionFixtures.streamID)
        let second = try sealer.seal(logical, streamID: TourSessionFixtures.streamID)

        #expect(first == second)
        #expect(first.encode() == second.encode())
        #expect(first.encode().lowercaseHex == "474f4832030002010000000000000000002a00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f0f1e2d3c4b5a69788796a5b4c3d2e1f000000050c7f03f42d9429524530ad6b2fdb72701e968b7d8c8b1f471366936db8c9e278bbea83db185892b7bfa27420165562877df907c7b735db72a8949fc7eb4fa46c3014b980fc13031a2c526ef32871ef1ad")
        #expect(first.encode().range(of: Data("Guest 7".utf8)) == nil)

        let opener = SessionFrameOpener(credential: credential)
        #expect(try opener.open(first) == .opened(try SessionEnvelope(
            majorVersion: SealedSessionEnvelope.majorVersion,
            minorVersion: SealedSessionEnvelope.minorVersion,
            lane: logical.lane,
            kind: logical.kind,
            flags: logical.flags,
            sequence: logical.sequence,
            sessionID: logical.sessionID,
            senderID: logical.senderID,
            payload: logical.payload
        )))
        #expect(try opener.open(second) == .duplicate(first.identity))

        let changed = try SessionEnvelope(
            lane: logical.lane,
            kind: logical.kind,
            flags: logical.flags,
            sequence: logical.sequence,
            sessionID: logical.sessionID,
            senderID: logical.senderID,
            payload: Data("different plaintext".utf8)
        )
        #expect(throws: SessionFrameSecurityError.identityReuse(first.identity)) {
            try sealer.seal(changed, streamID: TourSessionFixtures.streamID)
        }
    }

    @Test("Encrypted frame rejects tampering and another tour credential")
    func encryptedFrameAuthentication() throws {
        let sealed = try TourSessionFixtures.encryptedHelloFixture()
        var tampered = sealed.encode()
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let decodedTampered = try SealedSessionEnvelope.decode(tampered)
        let correctOpener = SessionFrameOpener(credential: try TourSessionFixtures.fixtureCredential())
        #expect(throws: SessionFrameSecurityError.authenticationFailed) {
            try correctOpener.open(decodedTampered)
        }

        let wrongCredential = try SessionCredential.derive(
            shortCode: "23456789AC",
            sessionID: TourSessionFixtures.sessionID
        )
        let wrongOpener = SessionFrameOpener(credential: wrongCredential)
        #expect(throws: SessionFrameSecurityError.authenticationFailed) {
            try wrongOpener.open(sealed)
        }
    }

    @Test("Encrypted protocol rejects a legacy major explicitly")
    func encryptedVersionMismatch() throws {
        var bytes = try TourSessionFixtures.encryptedHelloFixture().encode()
        bytes[4] = SessionEnvelope.majorVersion
        #expect(throws: SessionProtocolError.unsupportedMajorVersion(SessionEnvelope.majorVersion)) {
            try SealedSessionEnvelope.decode(bytes)
        }
    }

    @Test("Encoded audio frame and codec negotiation are deterministic")
    func encodedAudioFrame() throws {
        let fixture = try TourSessionFixtures.encodedAudioFixture()
        #expect(fixture.encode().lowercaseHex == "0100003e8001001400004e2000000000000000003b9aca00000000004a817c8000000006f8fffe010203")
        #expect(fixture.encode().count == EncodedAudioFramePayload.fixedHeaderSize + fixture.encodedBytes.count)
        #expect(try EncodedAudioFramePayload.decode(fixture.encode()) == fixture)

        let configurationWithCookie = try SessionAudioCodecConfiguration(
            codec: .aacLC,
            sampleRate: 16_000,
            channelCount: 1,
            frameDurationMilliseconds: 64,
            bitRate: 16_000,
            codecSpecificData: Data([0x12, 0x10])
        )
        let withCookie = try EncodedAudioFramePayload(
            configuration: configurationWithCookie,
            capturedAtNanoseconds: 10,
            expiresAtNanoseconds: 20,
            encodedBytes: Data([0xAA])
        )
        #expect(try EncodedAudioFramePayload.decode(withCookie.encode()) == withCookie)
        #expect(!fixture.isExpired(atNanoseconds: fixture.expiresAtNanoseconds - 1))
        #expect(fixture.isExpired(atNanoseconds: fixture.expiresAtNanoseconds))

        let all: SessionCapabilities = [.opusEncoder, .opusDecoder, .aacLCEncoder, .aacLCDecoder]
        #expect(try SessionAudioCodecNegotiation.preferredCodec(sender: all, receiver: all) == .opus)
        #expect(try SessionAudioCodecNegotiation.preferredCodec(
            sender: [.aacLCEncoder],
            receiver: [.aacLCDecoder]
        ) == .aacLC)
        #expect(throws: EncodedAudioFrameError.noCommonCodec) {
            try SessionAudioCodecNegotiation.preferredCodec(
                sender: [.opusEncoder],
                receiver: [.aacLCDecoder]
            )
        }
    }

    @Test("Realtime audio accumulation and jitter are bounded")
    func realtimeAudioBuffers() throws {
        var accumulator = try PCMFrameAccumulator(frameByteCount: 4)
        #expect(accumulator.append(Data([0, 1, 2])).isEmpty)
        #expect(accumulator.append(Data([3, 4, 5, 6, 7, 8])) == [
            Data([0, 1, 2, 3]),
            Data([4, 5, 6, 7]),
        ])
        #expect(accumulator.bufferedByteCount == 1)
        #expect(accumulator.append(Data([9, 10, 11])) == [Data([8, 9, 10, 11])])

        let payload = try EncodedAudioFramePayload(
            configuration: TourSessionFixtures.encodedAudioFixture().configuration,
            capturedAtNanoseconds: 100,
            expiresAtNanoseconds: 1_000,
            encodedBytes: Data([0x01])
        )
        var jitter = try EncodedAudioJitterBuffer(targetFrameCount: 3, maximumFrameCount: 4)
        #expect(jitter.offer(.init(sequence: 11, payload: payload), nowNanoseconds: 200) == .accepted)
        #expect(jitter.offer(.init(sequence: 10, payload: payload), nowNanoseconds: 200) == .accepted)
        #expect(jitter.popReady(nowNanoseconds: 200) == nil)
        #expect(jitter.offer(.init(sequence: 12, payload: payload), nowNanoseconds: 200) == .accepted)
        #expect(jitter.popReady(nowNanoseconds: 200)?.sequence == 10)
        #expect(jitter.popReady(nowNanoseconds: 200)?.sequence == 11)
        #expect(jitter.offer(.init(sequence: 10, payload: payload), nowNanoseconds: 200) == .duplicate)

        var full = try EncodedAudioJitterBuffer(targetFrameCount: 2, maximumFrameCount: 2)
        #expect(full.offer(.init(sequence: 1, payload: payload), nowNanoseconds: 200) == .accepted)
        #expect(full.offer(.init(sequence: 2, payload: payload), nowNanoseconds: 200) == .accepted)
        #expect(full.offer(.init(sequence: 3, payload: payload), nowNanoseconds: 200) == .capacityExceeded)
        #expect(full.offer(.init(sequence: 4, payload: payload), nowNanoseconds: 1_000) == .expired)
    }

    @Test("Message kinds cannot enter the wrong lane")
    func wrongLaneRejected() throws {
        #expect(throws: SessionProtocolError.wrongLane(kind: .audioFrame, actual: .control)) {
            try SessionEnvelope(
                lane: .control,
                kind: .audioFrame,
                sequence: 1,
                sessionID: TourSessionFixtures.sessionID,
                senderID: TourSessionFixtures.guestID,
                payload: Data()
            )
        }
    }

    @Test("Truncated payload fails loudly")
    func truncatedPayloadRejected() throws {
        var encoded = try TourSessionFixtures.helloEnvelope().encode()
        encoded.removeLast()
        #expect(throws: SessionProtocolError.invalidPayloadLength(expected: 64, actual: 63)) {
            try SessionEnvelope.decode(encoded)
        }
    }

    @Test("UTF-8 hello roundtrips")
    func utf8HelloRoundtrip() throws {
        let source = try HelloPayload(
            role: .guest,
            platform: .iOS,
            capabilities: 7,
            displayName: "ضيف",
            requestedLane: .asset,
            clientNonce: Data(repeating: 0x11, count: SessionAuthenticator.nonceSize),
            credentialProof: Data(repeating: 0x22, count: SessionAuthenticator.proofSize)
        )
        #expect(try HelloPayload.decode(source.encode()) == source)
    }

    @Test("Authentication proofs are stable and reject another tour code")
    func authenticationProofs() throws {
        #expect(try TourSessionFixtures.authenticationFixtureHex() ==
            "ae79db230a7910d38a2c941753c3ef29f0e0f74a7879cb5a04d1b450d7a2fb05|f304c62c6966c68cb380753be969776af76fee332070a59a3bf471d159b6b19b")

        let correct = try SessionCredential.derive(
            shortCode: "23456-789 ab",
            sessionID: TourSessionFixtures.sessionID
        )
        let wrong = try SessionCredential.derive(
            shortCode: "23456789AC",
            sessionID: TourSessionFixtures.sessionID
        )
        let challenge = Data(0x00 ... 0x0F)
        let client = Data(0x10 ... 0x1F)
        let expected = try SessionAuthenticator.guestProof(
            credential: correct,
            sessionID: TourSessionFixtures.sessionID,
            guideID: TourSessionFixtures.guideID,
            participantID: TourSessionFixtures.guestID,
            requestedLane: .control,
            challengeNonce: challenge,
            clientNonce: client,
            role: .guest,
            platform: .android,
            capabilities: 3,
            displayName: "Guest 7"
        )
        let invalid = try SessionAuthenticator.guestProof(
            credential: wrong,
            sessionID: TourSessionFixtures.sessionID,
            guideID: TourSessionFixtures.guideID,
            participantID: TourSessionFixtures.guestID,
            requestedLane: .control,
            challengeNonce: challenge,
            clientNonce: client,
            role: .guest,
            platform: .android,
            capabilities: 3,
            displayName: "Guest 7"
        )
        #expect(!SessionAuthenticator.securelyMatches(expected, invalid))
        #expect(throws: SessionSecurityError.invalidShortCode) {
            try SessionCredential.derive(shortCode: "O1IL", sessionID: TourSessionFixtures.sessionID)
        }
    }

    @Test("Authentication challenge and welcome roundtrip")
    func authenticationPayloadRoundtrip() throws {
        let challenge = try AuthChallengePayload(
            requestedLane: .asset,
            challengeNonce: Data(0x00 ... 0x0F)
        )
        #expect(try AuthChallengePayload.decode(challenge.encode()) == challenge)
        let welcome = try WelcomePayload(
            requestedLane: .asset,
            guideNonce: Data(0x20 ... 0x2F),
            credentialProof: Data(repeating: 0xAB, count: SessionAuthenticator.proofSize)
        )
        #expect(try WelcomePayload.decode(welcome.encode()) == welcome)
    }

    @Test("Wi-Fi Aware announcement has stable cross-platform bytes")
    func awareSessionAnnouncementRoundtrip() throws {
        let announcement = try AwareSessionAnnouncement(
            sessionID: TourSessionFixtures.sessionID,
            guideID: TourSessionFixtures.guideID,
            guidePlatform: .iOS,
            realtimePort: 51_000,
            controlPort: 51_001,
            assetPort: 51_002,
            channelName: "Alhambra",
            guideDisplayName: "Ahmed"
        )
        let encoded = try announcement.encode()
        #expect(encoded.lowercaseHex == "474f48410100112233445566778899aabbccddeeffffeeddccbbaa9988776655443322110001c738c739c73a0008416c68616d627261000541686d6564")
        #expect(try AwareSessionAnnouncement.decode(encoded) == announcement)
        #expect(throws: SessionProtocolError.invalidAwarePort) {
            try AwareSessionAnnouncement(
                sessionID: TourSessionFixtures.sessionID,
                guideID: TourSessionFixtures.guideID,
                guidePlatform: .iOS,
                realtimePort: 0,
                controlPort: 51_001,
                assetPort: 51_002,
                channelName: "Alhambra",
                guideDisplayName: "Ahmed"
            )
        }
    }
}

@Suite("Participant registry")
struct ParticipantRegistryTests {
    @Test("Reconnect replaces the old connection without incrementing listeners")
    func reconnectReplacement() {
        var registry = ParticipantRegistry()
        registry.register(ParticipantSession(
            participantID: TourSessionFixtures.guestID,
            connectionID: "old",
            displayName: "Guest 7",
            role: .guest,
            platform: .android
        ))
        registry.register(ParticipantSession(
            participantID: TourSessionFixtures.guestID,
            connectionID: "new",
            displayName: "Guest 7",
            role: .guest,
            platform: .android
        ))

        #expect(registry.listenerCount == 1)
        #expect(registry.disconnect(connectionID: "old") == nil)
        #expect(registry.listenerCount == 1)
        #expect(registry.disconnect(connectionID: "new")?.participantID == TourSessionFixtures.guestID)
        #expect(registry.listenerCount == 0)
    }

    @Test("Guide is not counted as a listener")
    func guideExcluded() {
        var registry = ParticipantRegistry()
        registry.register(ParticipantSession(
            participantID: TourSessionFixtures.sessionID,
            connectionID: "guide",
            displayName: "Guide",
            role: .guide,
            platform: .iOS
        ))
        #expect(registry.listenerCount == 0)
    }

    @Test(arguments: [1, 8, 20, 50])
    func scaleAndChurn(count: Int) {
        #expect(TourSessionFixtures.simulateParticipants(count: count) == "peak=\(count)|reconnect=\(count)|staleDisconnect=\(count)|final=0")
    }

    @Test("Realtime audit detects loss, duplicate, and reorder")
    func realtimeFaultAudit() {
        let audit = RealtimeSequenceAudit(sequences: [1, 2, 2, 5, 4, 7])
        #expect(audit.report == "unique=5|duplicates=1|reordered=1|missing=2")
    }

    @Test("Recovery simulation covers late join, reconnect, missing assets, and target replacement")
    func recoverySimulation() throws {
        #expect(try TourSessionFixtures.simulateRecovery() == "lateSlide=gate-left|lateTarget=9|reconnect=1|staleTarget=9|replacementTarget=10|missing=1|readyAfterFetch=true")
    }

    @Test("Visual focus is authoritative, versioned, and reconnectable")
    func visualFocusSimulation() {
        #expect(TourSessionFixtures.simulateVisualFocus() ==
            "initial=slides:0|guide=map:1,pointer:2|guest=pointer:2|stale=pointer:2|late=pointer:2")
    }

    @Test("Presentation, bearing, target, and tour pack roundtrip")
    func stateSnapshotsRoundtrip() throws {
        let presentation = PresentationSnapshotPayload(
            stateVersion: 7,
            deckID: TourSessionFixtures.deckID,
            currentSlideID: "gate-left",
            isVisible: true,
            effectiveAtMilliseconds: 123_456
        )
        #expect(try PresentationSnapshotPayload.decode(presentation.encode()) == presentation)

        let focus = VisualFocusSnapshotPayload(stateVersion: 10, mode: .map)
        #expect(focus.encode().count == 9)
        #expect(try VisualFocusSnapshotPayload.decode(focus.encode()) == focus)
        #expect(throws: SessionProtocolError.invalidVisualMode(4)) {
            try VisualFocusSnapshotPayload.decode(Data([0, 0, 0, 0, 0, 0, 0, 1, 4]))
        }

        let bearing = try BearingSnapshotPayload(
            stateVersion: 8,
            reference: .magnetic,
            bearingMilliDegrees: 271_250,
            isVisible: true
        )
        #expect(bearing.encode().count == 14)
        #expect(try BearingSnapshotPayload.decode(bearing.encode()) == bearing)

        let target = try TargetSnapshotPayload(
            stateVersion: 9,
            targetID: TourSessionFixtures.targetID,
            latitudeE7: 371_769_000,
            longitudeE7: -35_889_000,
            label: "Main Gate",
            isVisible: true
        )
        #expect(try TargetSnapshotPayload.decode(target.encode()) == target)

        let asset = try SlideAssetDescriptor(
            slideID: "gate-left",
            sha256: String(repeating: "ab", count: 32),
            byteLength: 4,
            order: 0,
            mimeType: "image/jpeg"
        )
        let manifest = try AssetManifestPayload(
            deckID: TourSessionFixtures.deckID,
            manifestVersion: 3,
            assets: [asset]
        )
        #expect(try AssetManifestPayload.decode(manifest.encode()) == manifest)

        let chunk = try AssetChunkPayload(
            sha256: asset.sha256,
            offset: 0,
            totalLength: 4,
            bytes: Data([1, 2, 3, 4])
        )
        #expect(try AssetChunkPayload.decode(chunk.encode()) == chunk)

        let request = try AssetRequestPayload(sha256: asset.sha256, offset: 2)
        #expect(try AssetRequestPayload.decode(request.encode()) == request)
        let status = try AssetStatusPayload(
            sha256: asset.sha256,
            status: .ready,
            byteLength: asset.byteLength,
            detail: ""
        )
        #expect(try AssetStatusPayload.decode(status.encode()) == status)

        let tourAsset = try TourAssetDescriptor(
            assetID: "gate-left",
            kind: .slide,
            sha256: asset.sha256,
            byteLength: asset.byteLength,
            order: asset.order,
            mimeType: asset.mimeType
        )
        let tourPack = try TourPackManifestPayload(
            packID: TourSessionFixtures.packID,
            manifestVersion: 4,
            displayName: "Alhambra",
            assets: [tourAsset]
        )
        #expect(try TourPackManifestPayload.decode(tourPack.encode()) == tourPack)
    }

    @Test("Target coordinates reject invalid geographic boundaries")
    func invalidTargetCoordinatesRejected() {
        #expect(throws: SessionProtocolError.invalidLatitudeE7(900_000_001)) {
            try TargetSnapshotPayload(
                stateVersion: 1,
                targetID: TourSessionFixtures.targetID,
                latitudeE7: 900_000_001,
                longitudeE7: 0,
                label: "",
                isVisible: true
            )
        }
        #expect(throws: SessionProtocolError.invalidLongitudeE7(-1_800_000_001)) {
            try TargetSnapshotPayload(
                stateVersion: 1,
                targetID: TourSessionFixtures.targetID,
                latitudeE7: 0,
                longitudeE7: -1_800_000_001,
                label: "",
                isVisible: true
            )
        }
    }

    @Test("Target snapshot survives 100 deterministic geographic roundtrips")
    func targetSnapshotDeterministicRoundtrips() throws {
        var randomState: UInt64 = 0x474f4832
        func next(_ upperBound: UInt64) -> UInt64 {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return randomState % upperBound
        }

        for index in 0 ..< 100 {
            let latitude = Int32(Int64(next(1_800_000_001)) - 900_000_000)
            let longitude = Int32(Int64(next(3_600_000_001)) - 1_800_000_000)
            let payload = try TargetSnapshotPayload(
                stateVersion: UInt64(index),
                targetID: TourSessionFixtures.targetID,
                latitudeE7: latitude,
                longitudeE7: longitude,
                label: "Target \(index)",
                isVisible: index.isMultiple(of: 2)
            )
            #expect(try TargetSnapshotPayload.decode(payload.encode()) == payload)
        }
    }

    @Test("Target guidance is calculated only from local inputs")
    func targetGuidance() {
        #expect(TargetGuidance.distanceMeters(
            fromLatitudeE7: 0,
            fromLongitudeE7: 0,
            toLatitudeE7: 0,
            toLongitudeE7: 0
        ) == 0)
        let eastBearing = TargetGuidance.initialBearingDegrees(
            fromLatitudeE7: 0,
            fromLongitudeE7: 0,
            toLatitudeE7: 0,
            toLongitudeE7: 10_000_000
        )
        #expect(abs(eastBearing - 90) < 0.000_001)
        #expect(abs(TargetGuidance.relativeArrowDegrees(targetBearing: 10, deviceHeading: 350) - 20) < 0.000_001)
        #expect(TargetGuidance.distanceMeters(
            fromLatitudeE7: 0,
            fromLongitudeE7: 0,
            toLatitudeE7: 0,
            toLongitudeE7: 1_800_000_000
        ).isFinite)
    }

    @Test("Hybrid routes prefer LAN and fall back to Wi-Fi Aware")
    func hybridRouteOrder() {
        #expect(SessionRouteAvailability(
            hasLANHost: true,
            hasWiFiAwareSession: true
        ).orderedRoutes == [.localLAN, .wifiAware])
        #expect(SessionRouteAvailability(
            hasLANHost: false,
            hasWiFiAwareSession: true
        ).orderedRoutes == [.wifiAware])
        #expect(SessionRouteAvailability(
            hasLANHost: false,
            hasWiFiAwareSession: false
        ).orderedRoutes.isEmpty)
    }

    @Test("One route lease owns every session lane")
    func oneRouteLease() {
        var lease = SessionRouteLease()
        let initialLAN = lease.select(.localLAN)
        let repeatedLAN = lease.select(.localLAN)
        let conflictingAware = lease.select(.wifiAware)
        #expect(initialLAN)
        #expect(repeatedLAN)
        #expect(!conflictingAware)
        lease.reset()
        let awareAfterReset = lease.select(.wifiAware)
        #expect(awareAfterReset)
    }
}
