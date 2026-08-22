import Foundation

public enum TourSessionFixtures {
    public static let sessionID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    public static let guestID = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
    public static let guideID = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
    public static let deckID = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
    public static let targetID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
    public static let packID = UUID(uuidString: "87654321-0FED-CBA9-8765-43210FEDCBA9")!

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

    public static func describeHello(_ encoded: Data) throws -> String {
        let envelope = try SessionEnvelope.decode(encoded)
        guard envelope.kind == .hello else {
            throw SessionProtocolError.unknownMessageKind(envelope.kind.rawValue)
        }
        let hello = try HelloPayload.decode(envelope.payload)
        return [
            "session=\(envelope.sessionID.uuidString.lowercased())",
            "sender=\(envelope.senderID.uuidString.lowercased())",
            "lane=\(envelope.lane)",
            "kind=\(envelope.kind)",
            "sequence=\(envelope.sequence)",
            "role=\(hello.role)",
            "platform=\(hello.platform)",
            "name=\(hello.displayName)",
            "capabilities=\(hello.capabilities)",
            "requestedLane=\(hello.requestedLane)",
        ].joined(separator: "|")
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
        let manifest = try AssetManifestPayload(deckID: deckID, manifestVersion: 3, assets: [asset])
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
        let tourPack = try TourPackManifestPayload(
            packID: packID,
            manifestVersion: 4,
            displayName: "Alhambra",
            assets: [slideAsset, mapAsset]
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
        return [
            presentationEnvelope.encode().lowercaseHex,
            bearingEnvelope.encode().lowercaseHex,
            targetEnvelope.encode().lowercaseHex,
            visualFocusEnvelope.encode().lowercaseHex,
            manifestEnvelope.encode().lowercaseHex,
            tourPackEnvelope.encode().lowercaseHex,
            requestEnvelope.encode().lowercaseHex,
            statusEnvelope.encode().lowercaseHex,
        ].joined(separator: "|")
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

    public static func deterministicUUID(index: Int) -> UUID {
        let suffix = String(format: "%012llx", UInt64(index))
        return UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-\(suffix)")!
    }
}
