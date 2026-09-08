import Foundation

public enum TourSessionFixtures {
    public static let sessionID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    public static let guestID = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
    public static let guideID = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
    public static let deckID = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
    public static let targetID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
    public static let packID = UUID(uuidString: "87654321-0FED-CBA9-8765-43210FEDCBA9")!
    public static let streamID = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!

    public static func helloEnvelope() throws -> SessionEnvelope {
        let hello = try HelloPayload(
            role: .guest,
            platform: .android,
            capabilities: 3,
            displayName: "Guest 7",
            requestedLane: .control,
            clientNonce: Data(0 ..< 16),
            credentialProof: Data(0xA0 ... 0xBF)
        )
        return try SessionEnvelope(
            lane: .control,
            kind: .hello,
            sequence: 42,
            sessionID: sessionID,
            senderID: guestID,
            payload: hello.encode()
        )
    }

    /// Describes one or more `|`-separated plaintext envelopes, one line per envelope. The
    /// output is the cross-language decode contract: payload enums as decimal raw values,
    /// UUIDs lowercased, bytes and free-form strings as lowercase UTF-8 hex (DSCN-21).
    public static func describeEnvelopes(_ hexList: String) throws -> String {
        try hexList.split(separator: "|", omittingEmptySubsequences: false).map { element in
            try describe(SessionEnvelope.decode(Data(hex: String(element))))
        }.joined(separator: "\n")
    }

    public static func describeAudioFrame(_ encoded: Data) throws -> String {
        let frame = try EncodedAudioFramePayload.decode(encoded)
        return [
            "codec=\(frame.configuration.codec.rawValue)",
            "sampleRate=\(frame.configuration.sampleRate)",
            "channelCount=\(frame.configuration.channelCount)",
            "frameDurationMilliseconds=\(frame.configuration.frameDurationMilliseconds)",
            "bitRate=\(frame.configuration.bitRate)",
            "codecSpecificData=\(frame.configuration.codecSpecificData.lowercaseHex)",
            "capturedAtNanoseconds=\(frame.capturedAtNanoseconds)",
            "expiresAtNanoseconds=\(frame.expiresAtNanoseconds)",
            "encodedBytes=\(frame.encodedBytes.lowercaseHex)",
        ].joined(separator: "|")
    }

    private static func text(_ value: String) -> String {
        Data(value.utf8).lowercaseHex
    }

    private static func describe(_ envelope: SessionEnvelope) throws -> String {
        var fields = [
            "session=\(envelope.sessionID.uuidString.lowercased())",
            "sender=\(envelope.senderID.uuidString.lowercased())",
            "lane=\(envelope.lane)",
            "kind=\(envelope.kind)",
            "sequence=\(envelope.sequence)",
        ]
        switch envelope.kind {
        case .hello:
            let hello = try HelloPayload.decode(envelope.payload)
            fields += [
                "role=\(hello.role.rawValue)",
                "platform=\(hello.platform.rawValue)",
                "name=\(text(hello.displayName))",
                "capabilities=\(hello.capabilities)",
                "requestedLane=\(hello.requestedLane.rawValue)",
            ]
        case .authChallenge:
            let challenge = try AuthChallengePayload.decode(envelope.payload)
            fields += [
                "requestedLane=\(challenge.requestedLane.rawValue)",
                "challengeNonce=\(challenge.challengeNonce.lowercaseHex)",
            ]
        case .welcome:
            let welcome = try WelcomePayload.decode(envelope.payload)
            fields += [
                "requestedLane=\(welcome.requestedLane.rawValue)",
                "guideNonce=\(welcome.guideNonce.lowercaseHex)",
                "credentialProof=\(welcome.credentialProof.lowercaseHex)",
            ]
        case .heartbeat, .leave:
            fields.append("payloadBytes=\(envelope.payload.count)")
        case .presentationSnapshot:
            let presentation = try PresentationSnapshotPayload.decode(envelope.payload)
            fields += [
                "stateVersion=\(presentation.stateVersion)",
                "deckID=\(presentation.deckID.uuidString.lowercased())",
                "slide=\(text(presentation.currentSlideID ?? ""))",
                "visible=\(presentation.isVisible)",
                "effectiveAtMilliseconds=\(presentation.effectiveAtMilliseconds)",
            ]
        case .bearingSnapshot:
            let bearing = try BearingSnapshotPayload.decode(envelope.payload)
            fields += [
                "stateVersion=\(bearing.stateVersion)",
                "reference=\(bearing.reference.rawValue)",
                "bearingMilliDegrees=\(bearing.bearingMilliDegrees)",
                "visible=\(bearing.isVisible)",
            ]
        case .targetSnapshot:
            let target = try TargetSnapshotPayload.decode(envelope.payload)
            fields += [
                "stateVersion=\(target.stateVersion)",
                "targetID=\(target.targetID.uuidString.lowercased())",
                "latitudeE7=\(target.latitudeE7)",
                "longitudeE7=\(target.longitudeE7)",
                "label=\(text(target.label))",
                "visible=\(target.isVisible)",
            ]
        case .visualFocusSnapshot:
            let focus = try VisualFocusSnapshotPayload.decode(envelope.payload)
            fields += ["stateVersion=\(focus.stateVersion)", "mode=\(focus.mode.rawValue)"]
        case .audioStatus:
            let status = try AudioReadinessPayload.decode(envelope.payload)
            fields += ["status=\(status.status.rawValue)", "revision=\(status.revision)"]
        case .assetManifest:
            let manifest = try AssetManifestPayload.decode(envelope.payload)
            let assets = manifest.assets.map {
                "\(text($0.slideID)),\($0.sha256),\($0.byteLength),\($0.order),\(text($0.mimeType))"
            }
            fields += [
                "deckID=\(manifest.deckID.uuidString.lowercased())",
                "manifestVersion=\(manifest.manifestVersion)",
                "assets=\(assets.joined(separator: ";"))",
            ]
        case .tourPackManifest:
            let manifest = try TourPackManifestPayload.decode(envelope.payload)
            let assets = manifest.assets.map {
                "\(text($0.assetID)),\($0.kind.rawValue),\($0.sha256),\($0.byteLength),\($0.order),\(text($0.mimeType))"
            }
            fields += [
                "packID=\(manifest.packID.uuidString.lowercased())",
                "manifestVersion=\(manifest.manifestVersion)",
                "displayName=\(text(manifest.displayName))",
                "assets=\(assets.joined(separator: ";"))",
            ]
        case .assetChunk:
            let chunk = try AssetChunkPayload.decode(envelope.payload)
            fields += [
                "sha256=\(chunk.sha256)",
                "offset=\(chunk.offset)",
                "totalLength=\(chunk.totalLength)",
                "bytes=\(chunk.bytes.lowercaseHex)",
            ]
        case .assetRequest:
            let request = try AssetRequestPayload.decode(envelope.payload)
            fields += ["sha256=\(request.sha256)", "offset=\(request.offset)"]
        case .assetStatus:
            let status = try AssetStatusPayload.decode(envelope.payload)
            fields += [
                "sha256=\(status.sha256)",
                "status=\(status.status.rawValue)",
                "byteLength=\(status.byteLength)",
                "detail=\(text(status.detail))",
            ]
        case .audioFrame:
            fields.append("audio=\(try describeAudioFrame(envelope.payload))")
        }
        return fields.joined(separator: "|")
    }

    public static func encryptedHelloFixture() throws -> SealedSessionEnvelope {
        let sealer = SessionFrameSealer(credential: try fixtureCredential())
        return try sealer.seal(helloEnvelope(), streamID: streamID)
    }

    /// Opens one sealed envelope with the fixture credential and describes it.
    public static func describeSealed(_ encoded: Data) throws -> String {
        let sealed = try SealedSessionEnvelope.decode(encoded)
        let opener = SessionFrameOpener(credential: try fixtureCredential())
        guard case let .opened(envelope) = try opener.open(sealed) else {
            preconditionFailure("a fresh fixture cannot be a duplicate")
        }
        return "version=\(SealedSessionEnvelope.majorVersion).\(sealed.minorVersion)"
            + "|stream=\(sealed.streamID.uuidString.lowercased())|"
            + (try describe(envelope))
    }

    public static func encodedAudioFixture() throws -> EncodedAudioFramePayload {
        try EncodedAudioFramePayload(
            configuration: SessionAudioCodecConfiguration(
                codec: .opus,
                sampleRate: 16_000,
                channelCount: 1,
                frameDurationMilliseconds: 20,
                bitRate: 20_000
            ),
            capturedAtNanoseconds: 1_000_000_000,
            expiresAtNanoseconds: 1_250_000_000,
            encodedBytes: Data([0xF8, 0xFF, 0xFE, 0x01, 0x02, 0x03])
        )
    }

    public static func simulateParticipants(count: Int) -> String {
        precondition(count >= 0)
        var registry = ParticipantRegistry()
        var currentConnections = [String]()

        for index in 0 ..< count {
            let participant = ParticipantSession(
                participantID: deterministicUUID(index: index),
                connectionID: "initial-\(index)",
                displayName: "Guest \(index)",
                role: .guest,
                platform: index.isMultiple(of: 2) ? .iOS : .android
            )
            registry.register(participant)
            currentConnections.append(participant.connectionID)
        }
        let peak = registry.listenerCount

        for index in 0 ..< count {
            let replacement = ParticipantSession(
                participantID: deterministicUUID(index: index),
                connectionID: "replacement-\(index)",
                displayName: "Guest \(index)",
                role: .guest,
                platform: index.isMultiple(of: 2) ? .iOS : .android
            )
            registry.register(replacement)
        }
        let afterReconnect = registry.listenerCount

        for connection in currentConnections {
            registry.disconnect(connectionID: connection)
        }
        let afterStaleDisconnect = registry.listenerCount

        for index in 0 ..< count {
            registry.disconnect(connectionID: "replacement-\(index)")
        }

        return "peak=\(peak)|reconnect=\(afterReconnect)|staleDisconnect=\(afterStaleDisconnect)|final=\(registry.listenerCount)"
    }

    public static func stateFixtureHex() throws -> String {
        let presentation = PresentationSnapshotPayload(
            stateVersion: 7,
            deckID: deckID,
            currentSlideID: "gate-left",
            isVisible: true,
            effectiveAtMilliseconds: 123_456
        )
        let presentationEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .presentationSnapshot,
            sequence: 9,
            sessionID: sessionID,
            senderID: guideID,
            payload: presentation.encode()
        )
        let bearing = try BearingSnapshotPayload(
            stateVersion: 8,
            reference: .magnetic,
            bearingMilliDegrees: 271_250,
            isVisible: true
        )
        let bearingEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .bearingSnapshot,
            sequence: 10,
            sessionID: sessionID,
            senderID: guideID,
            payload: bearing.encode()
        )
        let target = try TargetSnapshotPayload(
            stateVersion: 9,
            targetID: targetID,
            latitudeE7: 371_769_000,
            longitudeE7: -35_889_000,
            label: "Main Gate",
            isVisible: true
        )
        let targetEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .targetSnapshot,
            sequence: 11,
            sessionID: sessionID,
            senderID: guideID,
            payload: target.encode()
        )
        let visualFocus = VisualFocusSnapshotPayload(stateVersion: 10, mode: .map)
        let visualFocusEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .visualFocusSnapshot,
            sequence: 12,
            sessionID: sessionID,
            senderID: guideID,
            payload: visualFocus.encode()
        )
        let asset = try SlideAssetDescriptor(
            slideID: "gate-left",
            sha256: (0 ..< 32).map { String(format: "%02x", $0) }.joined(),
            byteLength: 2048,
            order: 0,
            mimeType: "image/jpeg"
        )
        // Two more slides share `order: 0` so the fixture pins the UTF-8 tie-break (DSCN-7):
        // U+FF5E (ef bd 9e) precedes U+1F5FA (f0 9f 97 ba) although UTF-16 orders them the other way.
        let astralSlide = try SlideAssetDescriptor(
            slideID: "gate-\u{1F5FA}",
            sha256: String(repeating: "ef", count: 32),
            byteLength: 512,
            order: 0,
            mimeType: "image/jpeg"
        )
        let fullwidthSlide = try SlideAssetDescriptor(
            slideID: "gate-\u{FF5E}",
            sha256: String(repeating: "12", count: 32),
            byteLength: 256,
            order: 0,
            mimeType: "image/jpeg"
        )
        let manifest = try AssetManifestPayload(
            deckID: deckID,
            manifestVersion: 3,
            assets: [astralSlide, asset, fullwidthSlide]
        )
        let manifestEnvelope = try SessionEnvelope(
            lane: .asset,
            kind: .assetManifest,
            sequence: 12,
            sessionID: sessionID,
            senderID: guideID,
            payload: manifest.encode()
        )
        let mapAsset = try TourAssetDescriptor(
            assetID: "alhambra-map",
            kind: .mapArchive,
            sha256: String(repeating: "cd", count: 32),
            byteLength: 4096,
            order: 0,
            mimeType: "application/vnd.pmtiles"
        )
        let slideAsset = try TourAssetDescriptor(
            assetID: "gate-left",
            kind: .slide,
            sha256: String(repeating: "ab", count: 32),
            byteLength: 2048,
            order: 1,
            mimeType: "image/jpeg"
        )
        let astralAsset = try TourAssetDescriptor(
            assetID: "plaza-\u{1F5FA}",
            kind: .slide,
            sha256: String(repeating: "ef", count: 32),
            byteLength: 512,
            order: 2,
            mimeType: "image/jpeg"
        )
        let fullwidthAsset = try TourAssetDescriptor(
            assetID: "plaza-\u{FF5E}",
            kind: .slide,
            sha256: String(repeating: "12", count: 32),
            byteLength: 256,
            order: 2,
            mimeType: "image/jpeg"
        )
        let tourPack = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 4,
            displayName: "Alhambra",
            assets: [slideAsset, astralAsset, mapAsset, fullwidthAsset]
        )
        let tourPackEnvelope = try SessionEnvelope(
            lane: .asset,
            kind: .tourPackManifest,
            sequence: 13,
            sessionID: sessionID,
            senderID: guideID,
            payload: tourPack.encode()
        )
        let request = try AssetRequestPayload(sha256: asset.sha256, offset: 1024)
        let requestEnvelope = try SessionEnvelope(
            lane: .asset,
            kind: .assetRequest,
            sequence: 14,
            sessionID: sessionID,
            senderID: guestID,
            payload: request.encode()
        )
        let status = try AssetStatusPayload(
            sha256: asset.sha256,
            status: .ready,
            byteLength: asset.byteLength,
            detail: ""
        )
        let statusEnvelope = try SessionEnvelope(
            lane: .asset,
            kind: .assetStatus,
            sequence: 15,
            sessionID: sessionID,
            senderID: guestID,
            payload: status.encode()
        )
        let chunk = try AssetChunkPayload(
            sha256: asset.sha256,
            offset: 1024,
            totalLength: asset.byteLength,
            bytes: Data(0x30 ... 0x3F)
        )
        let chunkEnvelope = try SessionEnvelope(
            lane: .asset,
            kind: .assetChunk,
            sequence: 16,
            sessionID: sessionID,
            senderID: guideID,
            payload: chunk.encode()
        )
        return [
            presentationEnvelope.encode().lowercaseHex,
            bearingEnvelope.encode().lowercaseHex,
            targetEnvelope.encode().lowercaseHex,
            visualFocusEnvelope.encode().lowercaseHex,
            manifestEnvelope.encode().lowercaseHex,
            tourPackEnvelope.encode().lowercaseHex,
            requestEnvelope.encode().lowercaseHex,
            statusEnvelope.encode().lowercaseHex,
            chunkEnvelope.encode().lowercaseHex,
        ].joined(separator: "|")
    }

    /// Plaintext authChallenge, welcome, and leave envelopes as they appear before and after
    /// admission on every lane. The leave payload is empty, matching production.
    public static func handshakeFixtureHex() throws -> String {
        let challenge = try AuthChallengePayload(requestedLane: .control, challengeNonce: Data(0x00 ... 0x0F))
        let challengeEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .authChallenge,
            sequence: 1,
            sessionID: sessionID,
            senderID: guideID,
            payload: challenge.encode()
        )
        let welcome = try WelcomePayload(
            requestedLane: .control,
            guideNonce: Data(0x20 ... 0x2F),
            credentialProof: Data(0xC0 ... 0xDF)
        )
        let welcomeEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .welcome,
            sequence: 2,
            sessionID: sessionID,
            senderID: guideID,
            payload: welcome.encode()
        )
        let leaveEnvelope = try SessionEnvelope(
            lane: .control,
            kind: .leave,
            sequence: 43,
            sessionID: sessionID,
            senderID: guestID,
            payload: Data()
        )
        return [
            challengeEnvelope.encode().lowercaseHex,
            welcomeEnvelope.encode().lowercaseHex,
            leaveEnvelope.encode().lowercaseHex,
        ].joined(separator: "|")
    }

    public static func realtimeAudioEnvelope() throws -> SessionEnvelope {
        try SessionEnvelope(
            lane: .realtime,
            kind: .audioFrame,
            sequence: 77,
            sessionID: sessionID,
            senderID: guideID,
            payload: encodedAudioFixture().encode()
        )
    }

    /// The realtime audioFrame envelope sealed exactly as it travels on the wire.
    public static func encryptedRealtimeFixture() throws -> SealedSessionEnvelope {
        try SessionFrameSealer(credential: fixtureCredential()).seal(realtimeAudioEnvelope(), streamID: streamID)
    }

    public static func authenticationFixtureHex() throws -> String {
        let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        let challengeNonce = Data(0x00 ... 0x0F)
        let clientNonce = Data(0x10 ... 0x1F)
        let guideNonce = Data(0x20 ... 0x2F)
        let guestProof = try SessionAuthenticator.guestProof(
            credential: credential,
            sessionID: sessionID,
            guideID: guideID,
            participantID: guestID,
            requestedLane: .control,
            challengeNonce: challengeNonce,
            clientNonce: clientNonce,
            role: .guest,
            platform: .android,
            capabilities: 3,
            displayName: "Guest 7"
        )
        let guideProof = try SessionAuthenticator.guideProof(
            credential: credential,
            sessionID: sessionID,
            guideID: guideID,
            participantID: guestID,
            requestedLane: .control,
            challengeNonce: challengeNonce,
            clientNonce: clientNonce,
            guideNonce: guideNonce
        )
        return "\(guestProof.lowercaseHex)|\(guideProof.lowercaseHex)"
    }

    public static func fixtureCredential() throws -> SessionCredential {
        try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
    }

    public static func simulateRecovery() throws -> String {
        let guidePresentation = PresentationSnapshotPayload(
            stateVersion: 7,
            deckID: deckID,
            currentSlideID: "gate-left",
            isVisible: true,
            effectiveAtMilliseconds: 123_456
        )
        let guideTarget = try TargetSnapshotPayload(
            stateVersion: 9,
            targetID: targetID,
            latitudeE7: 371_769_000,
            longitudeE7: -35_889_000,
            label: "Main Gate",
            isVisible: true
        )

        let lateJoinPresentation = try PresentationSnapshotPayload.decode(guidePresentation.encode())
        var guestTarget = try TargetSnapshotPayload.decode(guideTarget.encode())
        let lateJoinTargetVersion = guestTarget.stateVersion

        let staleTarget = try TargetSnapshotPayload(
            stateVersion: 8,
            targetID: targetID,
            latitudeE7: 0,
            longitudeE7: 0,
            label: "Stale",
            isVisible: false
        )
        if staleTarget.stateVersion > guestTarget.stateVersion { guestTarget = staleTarget }
        let versionAfterStaleTarget = guestTarget.stateVersion

        let replacementTarget = try TargetSnapshotPayload(
            stateVersion: 10,
            targetID: targetID,
            latitudeE7: 371_761_284,
            longitudeE7: -35_881_412,
            label: "Replacement",
            isVisible: true
        )
        if replacementTarget.stateVersion > guestTarget.stateVersion { guestTarget = replacementTarget }

        let mapAsset = try TourAssetDescriptor(
            assetID: "alhambra-map",
            kind: .mapArchive,
            sha256: String(repeating: "cd", count: 32),
            byteLength: 4_096,
            order: 0,
            mimeType: "application/vnd.pmtiles"
        )
        let slideAsset = try TourAssetDescriptor(
            assetID: "gate-left",
            kind: .slide,
            sha256: String(repeating: "ab", count: 32),
            byteLength: 2_048,
            order: 1,
            mimeType: "image/jpeg"
        )
        let manifest = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 4,
            displayName: "Alhambra",
            assets: [slideAsset, mapAsset]
        )
        var readyHashes: Set<String> = [mapAsset.sha256]
        let missingHashes = manifest.assets.map(\.sha256).filter { !readyHashes.contains($0) }
        readyHashes.formUnion(missingHashes)
        let readyAfterFetch = manifest.assets.allSatisfy { readyHashes.contains($0.sha256) }

        var registry = ParticipantRegistry()
        registry.register(ParticipantSession(
            participantID: guestID,
            connectionID: "initial",
            displayName: "Guest 7",
            role: .guest,
            platform: .android
        ))
        registry.register(ParticipantSession(
            participantID: guestID,
            connectionID: "replacement",
            displayName: "Guest 7",
            role: .guest,
            platform: .android
        ))
        registry.disconnect(connectionID: "initial")

        return [
            "lateSlide=\(lateJoinPresentation.currentSlideID ?? "none")",
            "lateTarget=\(lateJoinTargetVersion)",
            "reconnect=\(registry.listenerCount)",
            "staleTarget=\(versionAfterStaleTarget)",
            "replacementTarget=\(guestTarget.stateVersion)",
            "missing=\(missingHashes.count)",
            "readyAfterFetch=\(readyAfterFetch)",
        ].joined(separator: "|")
    }

    public static func simulateVisualFocus() -> String {
        let initial = VisualFocusSnapshotPayload(stateVersion: 0, mode: .slides)
        let map = VisualFocusSnapshotPayload(stateVersion: 1, mode: .map)
        let pointer = VisualFocusSnapshotPayload(stateVersion: 2, mode: .pointer)
        var guest = initial
        for incoming in [map, pointer] where incoming.stateVersion > guest.stateVersion {
            guest = incoming
        }
        let beforeStale = guest
        if map.stateVersion > guest.stateVersion { guest = map }
        let late = pointer
        return [
            "initial=\(initial.mode):\(initial.stateVersion)",
            "guide=\(map.mode):\(map.stateVersion),\(pointer.mode):\(pointer.stateVersion)",
            "guest=\(beforeStale.mode):\(beforeStale.stateVersion)",
            "stale=\(guest.mode):\(guest.stateVersion)",
            "late=\(late.mode):\(late.stateVersion)",
        ].joined(separator: "|")
    }

    /// Deterministic playout-decision script shared with the Kotlin core (ADR-045). Every pop is
    /// at now=200 except the final pop at 2_000, which expires the buffered frame 12.
    /// Tokens: `w` wait, `f<seq>` frame, `c<seq>` conceal. Expected: `w,w,f1,f2,w,c3,f4,f10,f11,w`.
    public static func simulatePlayout() throws -> String {
        let payload = try EncodedAudioFramePayload(
            configuration: encodedAudioFixture().configuration,
            capturedAtNanoseconds: 100,
            expiresAtNanoseconds: 1_000,
            encodedBytes: Data([0x01])
        )
        var jitter = try EncodedAudioJitterBuffer(targetFrameCount: 2, maximumFrameCount: 4)
        var tokens: [String] = []
        func pop(_ now: UInt64) {
            switch jitter.popForPlayout(nowNanoseconds: now) {
            case .wait: tokens.append("w")
            case let .frame(frame): tokens.append("f\(frame.sequence)")
            case let .conceal(missing): tokens.append("c\(missing)")
            }
        }
        func offer(_ sequence: UInt64) {
            _ = jitter.offer(SequencedEncodedAudioFrame(sequence: sequence, payload: payload), nowNanoseconds: 200)
        }
        pop(200)
        offer(1); pop(200)
        offer(2); pop(200); pop(200); pop(200)
        offer(4); pop(200); pop(200)
        offer(10); offer(11); pop(200); pop(200)
        offer(12); pop(2_000)
        return tokens.joined(separator: ",")
    }

    public static func deterministicUUID(index: Int) -> UUID {
        let suffix = String(format: "%012llx", UInt64(index))
        return UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-\(suffix)")!
    }
}
