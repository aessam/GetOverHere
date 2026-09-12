import Foundation
import TourSessionCore

@main
enum TourSessionCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            fail("usage: tour-session-swift fixture | encrypted-fixture | decode HEX[|HEX...] | decode-encrypted HEX | decode-audio HEX | audio-fixture | handshake | realtime-fixture | nearby-fixture | simulate COUNT | faults | playout | state | auth | recovery | focus")
        }

        switch command {
        case "gateway-fixture":
            do { try gatewayFixture() }
            catch { fail("gateway fixture failed: \(String(describing: type(of: error)))") }
        case "gateway-decode":
            guard arguments.count == 3 else { fail("gateway-decode requires pairing|lane|descriptor HEX or qr TEXT") }
            do {
                if arguments[1] == "qr" { print(try GatewayPairingMessage.decodeQR(arguments[2]).qrString) }
                else {
                    let bytes = try Data(hex: arguments[2])
                    switch arguments[1] {
                    case "pairing": print(try GatewayPairingMessage.decode(bytes).encode().lowercaseHex)
                    case "lane": print(try GatewayLaneRequest.decode(bytes).encode().lowercaseHex)
                    case "descriptor": print(try GatewayRoomDescriptor.decode(bytes).encode().lowercaseHex)
                    default: fail("unknown gateway record kind")
                    }
                }
            } catch { fail("gateway rejected: \(String(describing: type(of: error)))") }
        case "bluetooth-lanes-fixture":
            print(try BluetoothLanePSMs(admission: 128, realtime: 129, control: 256, asset: 65535).encode().lowercaseHex)
        case "audio-readiness-fixture":
            print(AudioReadinessPayload(status: .playing, revision: 0x0102030405060708).encode().lowercaseHex)
        case "bluetooth-v2-fixture":
            print(try BluetoothRoomRecord(roomID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
                guideID: UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!, name: "Tour",
                isAndroid: true, isLocked: true, admissionVersion: 2).encode().lowercaseHex)
        case "room-v2-guide", "room-v2-guest":
            do { try roomAdmissionV2(arguments) }
            catch { fail("admission-v2 rejected: \(error.localizedDescription)") }
        case "sign-guide":
            let frame = try TourSessionFixtures.encryptedRealtimeFixture()
            let signer = GuideFrameSigner(sessionID: frame.sessionID, guideID: frame.senderID)
            print(signer.publicKey.lowercaseHex)
            print(try signer.sign(frame).encode().lowercaseHex)
        case "verify-guide":
            guard arguments.count == 3 else { fail("verify-guide requires PINNED_KEY_HEX PACKET_HEX") }
            do {
                let frame = try TourSessionFixtures.encryptedRealtimeFixture()
                let verifier = try GuideFrameVerifier(pinnedPublicKey: Data(hex: arguments[1]),
                    sessionID: frame.sessionID, guideID: frame.senderID)
                print(try verifier.verify(Data(hex: arguments[2])).encode().lowercaseHex)
            } catch { fail("guide signature rejected") }
        case "nearby-fixture":
            for lane in NearbyLaneRequest.Lane.allCases {
                let room = lane == .metadata ? NearbyLaneRequest.metadataRoomID : UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
                print(try NearbyLaneRequest(lane: lane, roomID: room).encode().lowercaseHex)
            }
            var queue = NearbyRealtimeQueue()
            try queue.offer(Data([99]), audio: false, nowMilliseconds: 0)
            for index in 0..<100 { try queue.offer(Data([UInt8(index)]), audio: true, nowMilliseconds: UInt64(index)) }
            while let bytes = queue.next(nowMilliseconds: 245) { print(bytes.lowercaseHex) }
            print("dropped=\(queue.dropped)")
        case "room-guide", "room-guest":
            guard arguments.count == 3 else { fail("room-guide/room-guest requires UUID CODE (use - for open)") }
            guard let id = UUID(uuidString: arguments[1]) else { fail("invalid session UUID") }
            let code: String? = arguments[2] == "-" ? nil : arguments[2]
            func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            func receive() throws -> Data {
                guard let line = readLine() else { fail("admission input closed") }
                return try Data(hex: line)
            }
            if command == "room-guide" {
                let guide = RoomAdmission.Guide(sessionID: id, policy: try RoomAccessPolicy(sessionID: id, code: code))
                emit(guide.challenge.lowercaseHex)
                emit(try guide.reply(to: receive(), sessionCode: "23456789AB").lowercaseHex)
            } else {
                let guest = try RoomAdmission.Guest(challenge: receive(), sessionID: id, code: code)
                emit(guest.request.lowercaseHex)
                emit(try guest.open(receive()))
            }
        case "fixture":
            print(try TourSessionFixtures.helloEnvelope().encode().lowercaseHex)
        case "encrypted-fixture":
            print(try TourSessionFixtures.encryptedHelloFixture().encode().lowercaseHex)
        case "decode":
            guard arguments.count == 2 else { fail("decode requires one |-separated hex argument") }
            print(try TourSessionFixtures.describeEnvelopes(arguments[1]))
        case "decode-encrypted":
            guard arguments.count == 2 else { fail("decode-encrypted requires one hex argument") }
            print(try TourSessionFixtures.describeSealed(Data(hex: arguments[1])))
        case "decode-audio":
            guard arguments.count == 2 else { fail("decode-audio requires one hex argument") }
            print(try TourSessionFixtures.describeAudioFrame(Data(hex: arguments[1])))
        case "audio-fixture":
            print(try TourSessionFixtures.encodedAudioFixture().encode().lowercaseHex)
        case "handshake":
            print(try TourSessionFixtures.handshakeFixtureHex())
        case "realtime-fixture":
            print(try TourSessionFixtures.encryptedRealtimeFixture().encode().lowercaseHex)
        case "simulate":
            guard arguments.count == 2, let count = Int(arguments[1]), count >= 0 else {
                fail("simulate requires a non-negative integer")
            }
            print(TourSessionFixtures.simulateParticipants(count: count))
        case "faults":
            print(RealtimeSequenceAudit(sequences: [1, 2, 2, 5, 4, 7]).report)
        case "playout":
            print(try TourSessionFixtures.simulatePlayout())
        case "state":
            print(try TourSessionFixtures.stateFixtureHex())
        case "auth":
            print(try TourSessionFixtures.authenticationFixtureHex())
        case "recovery":
            print(try TourSessionFixtures.simulateRecovery())
        case "focus":
            print(TourSessionFixtures.simulateVisualFocus())
        default:
            fail("unknown command: \(command)")
        }
    }

    private static func gatewayFixture() throws {
        let pairing = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let room = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
        let guide = UUID(uuidString: "20314253-6475-8697-A8B9-CADBECFD0E1F")!
        let offer = try GatewayPairingMessage(role: .offer, pairingID: pairing, roomID: room, guideID: guide,
                                             expiresAtMilliseconds: 121_000,
                                             certificateFingerprint: Data(repeating: 0x11, count: 32),
                                             guideKeyFingerprint: Data(repeating: 0x22, count: 32),
                                             offerCertificateFingerprint: Data(repeating: 0x11, count: 32),
                                             host: "10.255.230.7", port: GatewayProtocol.servicePort)
        let response = try GatewayPairingMessage(role: .response, pairingID: pairing, roomID: room, guideID: guide,
                                                expiresAtMilliseconds: 121_000,
                                                certificateFingerprint: Data(repeating: 0x33, count: 32),
                                                guideKeyFingerprint: offer.guideKeyFingerprint,
                                                offerCertificateFingerprint: offer.certificateFingerprint,
                                                host: "", port: 0)
        print(offer.encode().lowercaseHex); print(response.encode().lowercaseHex)
        print(offer.qrString); print(response.qrString)
        for lane in GatewayLaneRequest.Lane.allCases {
            print(try GatewayLaneRequest(pairingID: pairing, roomID: room,
                                         generation: lane == .hubControl ? 0 : 1, lane: lane).encode().lowercaseHex)
        }
        let record = BluetoothRoomRecord(roomID: room, guideID: guide, name: "Tour — جولة", isAndroid: false,
                                         isLocked: true, admissionVersion: 2)
        print(try GatewayRoomDescriptor(generation: 3, recordRevision: 5, record: record,
                                        guidePublicKey: Data([4]) + Data(repeating: 0x44, count: 64)).encode().lowercaseHex)
    }

    private static func roomAdmissionV2(_ arguments: [String]) throws {
        guard arguments.count == 4,
              let session = UUID(uuidString: arguments[1]), let guideID = UUID(uuidString: arguments[2]) else {
            fail("room-v2-guide/room-v2-guest requires SESSION_UUID GUIDE_UUID CODE (use - for open)")
        }
        let code: String? = arguments[3] == "-" ? nil : arguments[3]
        func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        func receive() throws -> Data {
            guard let line = readLine() else { fail("admission input closed") }
            return try Data(hex: line)
        }
        if arguments[0] == "room-v2-guide" {
            let signer = GuideFrameSigner(sessionID: session, guideID: guideID)
            let guide = try RoomAdmissionV2.Guide(sessionID: session,
                policy: RoomAccessPolicy(sessionID: session, code: code), signer: signer)
            emit(guide.challenge.lowercaseHex)
            emit(try guide.reply(to: receive(), mediaSecret: "23456789AB").lowercaseHex)
            let credential = try SessionCredential.derive(shortCode: "23456789AB", sessionID: session)
            let envelope = try SessionEnvelope(lane: .control, kind: .leave, sequence: 1,
                sessionID: session, senderID: guideID, payload: Data())
            let sealed = try SessionFrameSealer(credential: credential).seal(envelope, streamID: UUID())
            emit(try signer.sign(sealed).encode().lowercaseHex)
            emit(signer.publicKey.lowercaseHex)
        } else {
            let guest = try RoomAdmissionV2.Guest(challenge: receive(), sessionID: session,
                expectedGuideID: guideID, code: code)
            emit(guest.request.lowercaseHex)
            let admitted = try guest.open(receive())
            var pin = SessionGuidePin()
            try pin.accept(admitted.guideIdentity)
            let verifier = try GuideFrameVerifier(pinnedPublicKey: admitted.guideIdentity.publicKey,
                sessionID: session, guideID: guideID)
            let sealed = try verifier.verify(receive())
            let credential = try SessionCredential.derive(shortCode: admitted.mediaSecret, sessionID: session)
            guard case let .opened(envelope) = try SessionFrameOpener(credential: credential).open(sealed),
                  envelope.kind == .leave, envelope.sequence == 1, envelope.payload.isEmpty else {
                fail("admitted guide frame roundtrip failed")
            }
            emit(admitted.mediaSecret)
            emit(admitted.guideIdentity.publicKey.lowercaseHex)
            emit("signed-guide-ok")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        Foundation.exit(2)
    }
}
