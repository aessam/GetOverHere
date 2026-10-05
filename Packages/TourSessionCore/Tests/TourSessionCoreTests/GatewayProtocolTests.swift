import Foundation
import Testing
@testable import TourSessionCore

@Suite struct GatewayProtocolTests {
    @Test(arguments: [970_000, 993_000, 1_013_000, 1_149_999] as [UInt64])
    func receivedOfferAllowsBoundedSkew(now: UInt64) throws {
        try offer(expiry: 1_120_000).validateReceivedOffer(nowMilliseconds: now)
    }

    @Test(arguments: [0, 969_999, 1_150_000, UInt64.max] as [UInt64])
    func receivedOfferRejectsOutsideSkewWindow(now: UInt64) throws {
        #expect(throws: GatewayProtocolError.expired) {
            try offer(expiry: 1_120_000).validateReceivedOffer(nowMilliseconds: now)
        }
    }

    @Test func companionToleranceDoesNotExtendGuideAcceptance() throws {
        let value = try offer(expiry: 1_120_000)
        try value.validateReceivedOffer(nowMilliseconds: 1_120_001)
        #expect(throws: GatewayProtocolError.expired) { try value.validate(nowMilliseconds: 1_120_001) }
    }

    private let pairing = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let room = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
    private let guide = UUID(uuidString: "20314253-6475-8697-A8B9-CADBECFD0E1F")!

    private func offer(host: String = "10.255.230.7", expiry: UInt64 = 121_000) throws -> GatewayPairingMessage {
        try GatewayPairingMessage(role: .offer, pairingID: pairing, roomID: room, guideID: guide,
                                  expiresAtMilliseconds: expiry, certificateFingerprint: Data(repeating: 0x11, count: 32),
                                  guideKeyFingerprint: Data(repeating: 0x22, count: 32),
                                  offerCertificateFingerprint: Data(repeating: 0x11, count: 32),
                                  host: host, port: GatewayProtocol.servicePort)
    }

    @Test func pairingBinaryAndQRRoundtrip() throws {
        let value = try offer()
        #expect(try GatewayPairingMessage.decode(value.encode()) == value)
        #expect(try GatewayPairingMessage.decodeQR(value.qrString) == value)
        #expect(value.encode().count == 172)
        #expect(value.qrString.hasPrefix("goh-hub:1:R0hQMQ"))
        try value.validate(nowMilliseconds: 1_000)
    }

    @Test func responseBindsOfferAndCertificate() throws {
        let first = try offer()
        let response = try GatewayPairingMessage(role: .response, pairingID: pairing, roomID: room, guideID: guide,
                                                expiresAtMilliseconds: first.expiresAtMilliseconds,
                                                certificateFingerprint: Data(repeating: 0x33, count: 32),
                                                guideKeyFingerprint: first.guideKeyFingerprint,
                                                offerCertificateFingerprint: first.certificateFingerprint,
                                                host: "", port: 0)
        try response.validateResponse(to: first, nowMilliseconds: 2_000)
        #expect(try GatewayPairingMessage.decodeQR(response.qrString) == response)
        #expect(throws: GatewayProtocolError.expired) { try response.validateResponse(to: first, nowMilliseconds: 121_000) }
        #expect(throws: GatewayProtocolError.mismatchedPairing) {
            try response.validateResponse(to: offer(expiry: 122_000), nowMilliseconds: 2_000)
        }
        #expect(throws: GatewayProtocolError.mismatchedPairing) {
            try first.validateResponse(to: first, nowMilliseconds: 2_000)
        }
    }

    @Test func allTruncationsAndTrailingBytesFail() throws {
        let bytes = try offer().encode()
        for count in 0..<bytes.count {
            #expect(throws: (any Error).self) { try GatewayPairingMessage.decode(bytes.prefix(count)) }
        }
        #expect(throws: (any Error).self) { try GatewayPairingMessage.decode(bytes + Data([0])) }
        #expect(throws: (any Error).self) { try GatewayPairingMessage.decodeQR(offer().qrString + "=") }
        #expect(throws: (any Error).self) { try GatewayPairingMessage.decodeQR("https://example.invalid/" + offer().qrString) }
    }

    @Test func lifetimeAndHostShapeAreBounded() throws {
        #expect(throws: GatewayProtocolError.expired) { try offer().validate(nowMilliseconds: 0) }
        #expect(throws: GatewayProtocolError.malformed) { try offer(expiry: .max).validate(nowMilliseconds: 1_000) }
        #expect(throws: GatewayProtocolError.malformed) { try offer(host: "localhost\n") }
        #expect(throws: GatewayProtocolError.malformed) { try offer(host: "") }
        #expect(throws: GatewayProtocolError.malformed) { try offer(host: String(repeating: "a", count: 256)) }
        let longest = try offer(host: String(repeating: "a", count: 255))
        #expect(try GatewayPairingMessage.decodeQR(longest.qrString) == longest)
    }

    @Test(arguments: GatewayLaneRequest.Lane.allCases)
    func everyLaneUsesOnlyFixedDestination(_ lane: GatewayLaneRequest.Lane) throws {
        let request = try GatewayLaneRequest(pairingID: pairing, roomID: room,
                                             generation: lane == .hubControl ? 0 : 1, lane: lane)
        #expect(request.encode().count == 45)
        #expect(try GatewayLaneRequest.decode(request.encode()) == request)
        if let port = lane.localPort { #expect((50_000...50_003).contains(port)) }
        else { #expect(lane == .hubControl) }
        for length in 0..<45 {
            #expect(throws: (any Error).self) { try GatewayLaneRequest.decode(request.encode().prefix(length)) }
        }
    }

    @Test func unknownLanesAndWrongGenerationFail() throws {
        let request = try GatewayLaneRequest(pairingID: pairing, roomID: room, generation: 1, lane: .realtime)
        var bytes = request.encode(); bytes[44] = 255
        #expect(throws: GatewayProtocolError.malformed) { try GatewayLaneRequest.decode(bytes) }
        #expect(throws: GatewayProtocolError.malformed) {
            try GatewayLaneRequest(pairingID: pairing, roomID: room, generation: 0, lane: .admission)
        }
        #expect(throws: GatewayProtocolError.malformed) {
            try GatewayLaneRequest(pairingID: pairing, roomID: room, generation: 1, lane: .hubControl)
        }
        #expect(throws: GatewayProtocolError.malformed) { try GatewayLaneRequest.Lane(.metadata) }
    }

    @Test func descriptorKeepsOriginAndRejectsLegacyOrTruncation() throws {
        let record = BluetoothRoomRecord(roomID: room, guideID: guide, name: "جولة — 東京", isAndroid: false,
                                         isLocked: true, admissionVersion: 2)
        let key = Data([4]) + Data(repeating: 0x44, count: 64)
        let value = try GatewayRoomDescriptor(generation: 3, recordRevision: 5, record: record, guidePublicKey: key)
        #expect(try GatewayRoomDescriptor.decode(value.encode()) == value)
        #expect(!value.record.isAndroid)
        for count in 0..<(try value.encode().count) {
            #expect(throws: (any Error).self) { try GatewayRoomDescriptor.decode(value.encode().prefix(count)) }
        }
        #expect(throws: GatewayProtocolError.malformed) {
            try GatewayRoomDescriptor(generation: 1, recordRevision: 1,
                                      record: BluetoothRoomRecord(roomID: room, guideID: guide, name: "Legacy",
                                                                  isAndroid: true, isLocked: false), guidePublicKey: key)
        }
    }

    @Test func deterministicHundredDescriptorRoundtrips() throws {
        for index in 1...100 {
            let record = BluetoothRoomRecord(roomID: room, guideID: guide,
                                             name: "Tour \(index) · مرحبا · 東京" + String(repeating: "x", count: index),
                                             isAndroid: index.isMultiple(of: 2), isLocked: index.isMultiple(of: 3), admissionVersion: 2)
            let descriptor = try GatewayRoomDescriptor(generation: UInt64(index), recordRevision: UInt64(index * 3),
                                                       record: record, guidePublicKey: Data([4]) + Data(repeating: UInt8(index), count: 64))
            #expect(try GatewayRoomDescriptor.decode(descriptor.encode()) == descriptor)
        }
    }

    @Test func strictPolicyCannotUseLANOrBluetooth() {
        #expect(AllowedTransportPolicy.gatewayIOS.filtered(SessionTransportRoute.allCases) == [.applePeer])
        #expect(AllowedTransportPolicy.gatewayAndroid.filtered(SessionTransportRoute.allCases) == [.wifiAware])
        #expect(SessionTransportRoute.applePeer.rawValue == 4)
    }

    @Test func gatewayQueueDropsByLocalResidenceWithoutChangingBytes() throws {
        var queue = NearbyRealtimeQueue(lifetimeMilliseconds: GatewayProtocol.audioResidenceMilliseconds)
        let old = Data([1, 2, 3]), current = Data([4, 5, 6]), reliable = Data([7, 8, 9])
        try queue.offer(old, audio: true, nowMilliseconds: 0)
        try queue.offer(current, audio: true, nowMilliseconds: 30)
        try queue.offer(reliable, audio: false, nowMilliseconds: 0)
        #expect(queue.next(nowMilliseconds: 51) == current)
        #expect(queue.next(nowMilliseconds: 500) == reliable)
        #expect(queue.dropped == 1)
        #expect(queue.next(nowMilliseconds: 500) == nil)
    }
}
