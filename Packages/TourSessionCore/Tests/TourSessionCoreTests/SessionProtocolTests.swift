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
        #expect(first.encode().lowercaseHex == "474f4832040002010000000000000000002a00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f0f1e2d3c4b5a69788796a5b4c3d2e1f000000050eaa9f8c5e519d5a5fc368f8dbfe6d7e45d70eb96c32dd250490c747f03506c02a397edbef6eb9dfab3c4fd42eca6b528684123fa95a9649bb3e5ad5ee146d2953f14667726159f3dcfd266a5f1d98fa6")
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

    @Test("Encrypted frame authenticates and preserves the received minor version")
    func encryptedMinorVersion() throws {
        let credential = try TourSessionFixtures.fixtureCredential()
        let logical = try TourSessionFixtures.helloEnvelope()
        let sealed = try SessionFrameSealer(
            credential: credential,
            protocolMinorVersion: 1
        ).seal(logical, streamID: TourSessionFixtures.streamID)

        #expect(sealed.minorVersion == 1)
        let decoded = try SealedSessionEnvelope.decode(sealed.encode())
        #expect(decoded.minorVersion == 1)
        #expect(try SessionFrameOpener(credential: credential).open(decoded) == .opened(try SessionEnvelope(
            majorVersion: SealedSessionEnvelope.majorVersion,
            minorVersion: 1,
            lane: logical.lane,
            kind: logical.kind,
            flags: logical.flags,
            sequence: logical.sequence,
            sessionID: logical.sessionID,
            senderID: logical.senderID,
            payload: logical.payload
        )))

        var tamperedMinor = sealed.encode()
        tamperedMinor[5] = 2
        let decodedTamperedMinor = try SealedSessionEnvelope.decode(tamperedMinor)
        #expect(throws: SessionFrameSecurityError.authenticationFailed) {
            try SessionFrameOpener(credential: credential).open(decodedTamperedMinor)
        }
    }

    @Test("Replay window rejects an accepted frame after sequence eviction")
    func encryptedReplayWindow() throws {
        let credential = try TourSessionFixtures.fixtureCredential()
        let fixture = try TourSessionFixtures.helloEnvelope()
        let sealer = SessionFrameSealer(credential: credential)
        let frames = try (1 ... 4).map { sequence in
            try sealer.seal(
                SessionEnvelope(
                    lane: fixture.lane,
                    kind: fixture.kind,
                    flags: fixture.flags,
                    sequence: UInt64(sequence),
                    sessionID: fixture.sessionID,
                    senderID: fixture.senderID,
                    payload: fixture.payload
                ),
                streamID: TourSessionFixtures.streamID
            )
        }
        let opener = SessionFrameOpener(credential: credential, replayWindow: 3)

        #expect(try opener.open(frames[1]) == .opened(try SessionEnvelope(
            majorVersion: SealedSessionEnvelope.majorVersion,
            minorVersion: SealedSessionEnvelope.minorVersion,
            lane: fixture.lane,
            kind: fixture.kind,
            flags: fixture.flags,
            sequence: 2,
            sessionID: fixture.sessionID,
            senderID: fixture.senderID,
            payload: fixture.payload
        )))
        _ = try opener.open(frames[0])
        _ = try opener.open(frames[2])
        #expect(try opener.open(frames[0]) == .duplicate(frames[0].identity))
        _ = try opener.open(frames[3])
        #expect(throws: SessionFrameSecurityError.replayedFrame(frames[0].identity)) {
            try opener.open(frames[0])
        }
    }

    @Test("Encrypted protocol rejects legacy majors explicitly", arguments: [SessionEnvelope.majorVersion, UInt8(3)])
    func encryptedVersionMismatch(legacyMajor: UInt8) throws {
        var bytes = try TourSessionFixtures.encryptedHelloFixture().encode()
        bytes[4] = legacyMajor
        #expect(throws: SessionProtocolError.unsupportedMajorVersion(
            received: legacyMajor,
            supported: SealedSessionEnvelope.majorVersion
        )) {
            try SealedSessionEnvelope.decode(bytes)
        }
    }

    @Test("Plaintext version mismatch carries both majors")
    func plaintextVersionMismatchCarriesBothMajors() throws {
        var bytes = try TourSessionFixtures.helloEnvelope().encode()
        bytes[4] = SealedSessionEnvelope.majorVersion
        #expect(throws: SessionProtocolError.unsupportedMajorVersion(
            received: SealedSessionEnvelope.majorVersion,
            supported: SessionEnvelope.majorVersion
        )) {
            try SessionEnvelope.decode(bytes)
        }
        #expect(
            String(describing: SessionProtocolError.unsupportedMajorVersion(received: 3, supported: 2))
                == "unsupported major version 3; this build requires 2"
        )
    }

    @Test("Tour pack ordering is UTF-8 byte order with exact dedup")
    func tourPackOrderingIsUTF8ByteOrderWithExactDedup() throws {
        func asset(_ assetID: String, order: UInt32 = 0) throws -> TourAssetDescriptor {
            try TourAssetDescriptor(
                assetID: assetID,
                kind: .slide,
                sha256: String(repeating: "ab", count: 32),
                byteLength: 1,
                order: order,
                mimeType: "image/jpeg"
            )
        }
        let astral = "plaza-\u{1F5FA}"
        let fullwidth = "plaza-\u{FF5E}"
        let tie = try TourPackManifestPayload(
            packID: TourSessionFixtures.packID,
            manifestVersion: 1,
            displayName: "Tie",
            assets: [asset(astral), asset(fullwidth)]
        )
        #expect(tie.assets.map { Array($0.assetID.utf8) } == [Array(fullwidth.utf8), Array(astral.utf8)])
        let tieHex = try tie.encode().lowercaseHex
        #expect(tieHex == "876543210fedcba9876543210fedcba90000000000000001000354696500020009706c617a612defbd9e01abababababababababababababababababababababababababababababababab000000000000000100000000000a696d6167652f6a706567000a706c617a612df09f97ba01abababababababababababababababababababababababababababababababab000000000000000100000000000a696d6167652f6a706567")
        #expect(try TourPackManifestPayload.decode(tie.encode()).encode() == tie.encode())

        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        let canonical = try TourPackManifestPayload(
            packID: TourSessionFixtures.packID,
            manifestVersion: 1,
            displayName: "Tie",
            assets: [asset(nfc), asset(nfd)]
        )
        #expect(canonical.assets.count == 2)
        #expect(Array(canonical.assets[0].assetID.utf8) == [0x63, 0x61, 0x66, 0x65, 0xCC, 0x81])
        #expect(try TourPackManifestPayload.decode(canonical.encode()).encode() == canonical.encode())

        let signed = try TourPackManifestPayload(
            packID: TourSessionFixtures.packID,
            manifestVersion: 1,
            displayName: "Tie",
            assets: [asset("\u{00E9}"), asset("z")]
        )
        #expect(signed.assets.map { Array($0.assetID.utf8) } == [[0x7A], [0xC3, 0xA9]])
        let prefix = try TourPackManifestPayload(
            packID: TourSessionFixtures.packID,
            manifestVersion: 1,
            displayName: "Tie",
            assets: [asset("ab"), asset("a")]
        )
        #expect(prefix.assets.map { Array($0.assetID.utf8) } == [[0x61], [0x61, 0x62]])

        #expect(throws: SessionProtocolError.duplicateAssetID("gate-left")) {
            try TourPackManifestPayload(
                packID: TourSessionFixtures.packID,
                manifestVersion: 1,
                displayName: "Tie",
                assets: [asset("gate-left"), asset("gate-left", order: 1)]
            )
        }
    }

    @Test("Slide manifest ordering is UTF-8 byte order with exact dedup")
    func slideManifestOrderingIsUTF8ByteOrderWithExactDedup() throws {
        func slide(_ slideID: String, order: UInt32 = 0) throws -> SlideAssetDescriptor {
            try SlideAssetDescriptor(
                slideID: slideID,
                sha256: String(repeating: "ab", count: 32),
                byteLength: 1,
                order: order,
                mimeType: "image/jpeg"
            )
        }
        let astral = "gate-\u{1F5FA}"
        let fullwidth = "gate-\u{FF5E}"
        let tie = try AssetManifestPayload(
            deckID: TourSessionFixtures.deckID,
            manifestVersion: 1,
            assets: [slide(astral), slide("gate-left", order: 1), slide(fullwidth)]
        )
        #expect(tie.assets.map { Array($0.slideID.utf8) } == [
            Array(fullwidth.utf8),
            Array(astral.utf8),
            Array("gate-left".utf8),
        ])
        #expect(try AssetManifestPayload.decode(tie.encode()).encode() == tie.encode())
        #expect(try AssetManifestPayload.decode(tie.encode()).assets.map { Array($0.slideID.utf8) } == [
            Array(fullwidth.utf8),
            Array(astral.utf8),
            Array("gate-left".utf8),
        ])

        let signed = try AssetManifestPayload(
            deckID: TourSessionFixtures.deckID,
            manifestVersion: 1,
            assets: [slide("\u{00E9}"), slide("z")]
        )
        #expect(signed.assets.map { Array($0.slideID.utf8) } == [[0x7A], [0xC3, 0xA9]])
        let prefix = try AssetManifestPayload(
            deckID: TourSessionFixtures.deckID,
            manifestVersion: 1,
            assets: [slide("ab"), slide("a")]
        )
        #expect(prefix.assets.map { Array($0.slideID.utf8) } == [[0x61], [0x61, 0x62]])

        #expect(throws: SessionProtocolError.duplicateSlideID("gate-left")) {
            try AssetManifestPayload(
                deckID: TourSessionFixtures.deckID,
                manifestVersion: 1,
                assets: [slide("gate-left"), slide("gate-left", order: 1)]
            )
        }
    }

    @Test("Handshake fixture is stable")
    func handshakeFixtureIsStable() throws {
        let hex = try TourSessionFixtures.handshakeFixtureHex()
        #expect(hex == "474f4832020102050000000000000000000100112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000000001102000102030405060708090a0b0c0d0e0f|474f4832020102020000000000000000000200112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000000003102202122232425262728292a2b2c2d2e2fc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf|474f4832020102040000000000000000002b00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f00000000")
        let envelopes = try hex.split(separator: "|").map { try SessionEnvelope.decode(Data(hex: String($0))) }
        #expect(envelopes.map(\.kind) == [.authChallenge, .welcome, .leave])
        #expect(envelopes.map(\.senderID) == [
            TourSessionFixtures.guideID,
            TourSessionFixtures.guideID,
            TourSessionFixtures.guestID,
        ])
        #expect(envelopes.map(\.sequence) == [1, 2, 43])
        #expect(try AuthChallengePayload.decode(envelopes[0].payload) == AuthChallengePayload(
            requestedLane: .control,
            challengeNonce: Data(0x00 ... 0x0F)
        ))
        #expect(try WelcomePayload.decode(envelopes[1].payload) == WelcomePayload(
            requestedLane: .control,
            guideNonce: Data(0x20 ... 0x2F),
            credentialProof: Data(0xC0 ... 0xDF)
        ))
        #expect(envelopes[2].payload.isEmpty)
    }

    @Test("Realtime audio frame seals deterministically")
    func realtimeAudioFrameSealsDeterministically() throws {
        let sealed = try TourSessionFixtures.encryptedRealtimeFixture()
        #expect(sealed.encode().lowercaseHex == "474f4832040001100000000000000000004d00112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000f1e2d3c4b5a69788796a5b4c3d2e1f00000003adb8e5ed09b1fad51b1b2510ba6717d8d7f6542479429e44ea0349ee37b6ca4c834475e6c0e328fd8a8d8a2b6af8e80b05390378434de32c1675e")
        #expect(try TourSessionFixtures.encryptedRealtimeFixture().encode() == sealed.encode())
        let opener = SessionFrameOpener(credential: try TourSessionFixtures.fixtureCredential())
        let opened = try opener.open(sealed)
        guard case let .opened(envelope) = opened else {
            Issue.record("fresh realtime fixture opened as \(opened)")
            return
        }
        #expect(envelope.lane == .realtime)
        #expect(envelope.kind == .audioFrame)
        #expect(envelope.sequence == 77)
        #expect(envelope.senderID == TourSessionFixtures.guideID)
        #expect(try EncodedAudioFramePayload.decode(envelope.payload) == TourSessionFixtures.encodedAudioFixture())
    }

    @Test("State fixture describes every control and asset kind")
    func stateFixtureDescribesEveryControlAndAssetKind() throws {
        let stateDescription = [
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=presentationSnapshot|sequence=9|stateVersion=7|deckID=12345678-90ab-cdef-1234-567890abcdef|slide=676174652d6c656674|visible=true|effectiveAtMilliseconds=123456",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=bearingSnapshot|sequence=10|stateVersion=8|reference=1|bearingMilliDegrees=271250|visible=true",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=targetSnapshot|sequence=11|stateVersion=9|targetID=abcdef01-2345-6789-abcd-ef0123456789|latitudeE7=371769000|longitudeE7=-35889000|label=4d61696e2047617465|visible=true",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=visualFocusSnapshot|sequence=12|stateVersion=10|mode=2",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=asset|kind=assetManifest|sequence=12|deckID=12345678-90ab-cdef-1234-567890abcdef|manifestVersion=3|assets=676174652d6c656674,000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f,2048,0,696d6167652f6a706567;676174652defbd9e,1212121212121212121212121212121212121212121212121212121212121212,256,0,696d6167652f6a706567;676174652df09f97ba,efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef,512,0,696d6167652f6a706567",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=asset|kind=tourPackManifest|sequence=13|packID=87654321-0fed-cba9-8765-43210fedcba9|manifestVersion=4|displayName=416c68616d627261|assets=616c68616d6272612d6d6170,2,cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd,4096,0,6170706c69636174696f6e2f766e642e706d74696c6573;676174652d6c656674,1,abababababababababababababababababababababababababababababababab,2048,1,696d6167652f6a706567;706c617a612defbd9e,1,1212121212121212121212121212121212121212121212121212121212121212,256,2,696d6167652f6a706567;706c617a612df09f97ba,1,efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef,512,2,696d6167652f6a706567",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=10213243-5465-7687-98a9-bacbdcedfe0f|lane=asset|kind=assetRequest|sequence=14|sha256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f|offset=1024",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=10213243-5465-7687-98a9-bacbdcedfe0f|lane=asset|kind=assetStatus|sequence=15|sha256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f|status=1|byteLength=2048|detail=",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=asset|kind=assetChunk|sequence=16|sha256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f|offset=1024|totalLength=2048|bytes=303132333435363738393a3b3c3d3e3f",
        ].joined(separator: "\n")
        #expect(try TourSessionFixtures.describeEnvelopes(TourSessionFixtures.stateFixtureHex()) == stateDescription)

        let handshakeDescription = [
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=authChallenge|sequence=1|requestedLane=2|challengeNonce=000102030405060708090a0b0c0d0e0f",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=ffeeddcc-bbaa-9988-7766-554433221100|lane=control|kind=welcome|sequence=2|requestedLane=2|guideNonce=202122232425262728292a2b2c2d2e2f|credentialProof=c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf",
            "session=00112233-4455-6677-8899-aabbccddeeff|sender=10213243-5465-7687-98a9-bacbdcedfe0f|lane=control|kind=leave|sequence=43|payloadBytes=0",
        ].joined(separator: "\n")
        #expect(try TourSessionFixtures.describeEnvelopes(TourSessionFixtures.handshakeFixtureHex()) == handshakeDescription)

        let audioDescription = "codec=1|sampleRate=16000|channelCount=1|frameDurationMilliseconds=20|bitRate=20000|codecSpecificData=|capturedAtNanoseconds=1000000000|expiresAtNanoseconds=1250000000|encodedBytes=f8fffe010203"
        #expect(try TourSessionFixtures.describeAudioFrame(TourSessionFixtures.encodedAudioFixture().encode()) == audioDescription)

        let sealedDescription = try TourSessionFixtures.describeSealed(TourSessionFixtures.encryptedRealtimeFixture().encode())
        #expect(sealedDescription.hasPrefix(
            "version=\(SealedSessionEnvelope.majorVersion).\(SealedSessionEnvelope.minorVersion)"
                + "|stream=0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0|"
        ))
        #expect(sealedDescription.hasSuffix("|lane=realtime|kind=audioFrame|sequence=77|audio=" + audioDescription))
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
        #expect(full.offer(.init(sequence: 4, payload: payload), nowNanoseconds: 1_100) == .expired)

        var skewed = try EncodedAudioJitterBuffer(targetFrameCount: 1, maximumFrameCount: 2)
        #expect(skewed.offer(.init(sequence: 1, payload: payload), nowNanoseconds: 10_000) == .accepted)
        #expect(skewed.popReady(nowNanoseconds: 10_899)?.sequence == 1)
        #expect(skewed.offer(.init(sequence: 2, payload: payload), nowNanoseconds: 11_000) == .expired)
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
            "5f837f1767e9bddd9a65096b1b2f458f1329a4f1c9e9a4d09bb9f15f8225a86d|98950abd4bf6d1e9ef3ea546586c7d027797d5e379aab69f1b99c23067d90a8f")

        let correct = try SessionCredential.derive(
            shortCode: "23456-789 ab",
            sessionID: TourSessionFixtures.sessionID
        )
        #expect(correct.key == (try TourSessionFixtures.fixtureCredential()).key)
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

    @Test("Credential stretch is a PBKDF2 wire contract")
    func credentialStretchContract() throws {
        #expect(SealedSessionEnvelope.majorVersion == 4)
        #expect(SessionCredential.stretchIterations == 600_000)
        #expect(SessionCredential.stretchSaltLabel == "GetOverHere/GOH4/credential-salt/v1")
        #expect(SessionCredential.stretchedKeySize == 32)
        let fixtureSalt = try Data(hex: "00112233445566778899aabbccddeeff4765744f766572486572652f474f48342f63726564656e7469616c2d73616c742f7631")
        #expect(try SessionCredential.stretch(inputKey: Data("23456789AB".utf8), salt: fixtureSalt).lowercaseHex
            == "92ed1ff17b00d8ed95c29c42930eea012bf535f0375174f8c01b0caa46bef215")
        #expect(try TourSessionFixtures.fixtureCredential().key.lowercaseHex
            == "21ad5672cb5998d6c28ca6573e170ca605c0d71d22ae25ede7444c124ef4b1cf")
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
