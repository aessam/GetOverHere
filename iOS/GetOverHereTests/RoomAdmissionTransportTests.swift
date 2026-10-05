import Foundation
import Darwin
import Testing
import TourSessionCore
@testable import GetOverHere

@Suite(.serialized)
struct RoomAdmissionTransportTests {
    @Test func stopReleasesPortBeforeReturningEvenBeforeAcceptWorkerStarts() throws {
        let transport = RoomAdmissionTransport(port: 56005)
        let id = UUID()
        let signer = GuideFrameSigner(sessionID: id, guideID: UUID())
        defer { transport.stop() }
        for _ in 0..<100 {
            try transport.start(sessionID: id, sessionCode: "23456789AB", signer: signer)
            transport.stop()
        }
    }

    @Test func stoppedIdleListenerCanImmediatelyHostAnotherRoom() async throws {
        let transport = RoomAdmissionTransport(port: 56004)
        defer { transport.stop() }
        for _ in 0..<3 {
            let id = UUID()
            let signer = GuideFrameSigner(sessionID: id, guideID: UUID())
            try transport.start(sessionID: id, sessionCode: "23456789AB", signer: signer)
            // Let the worker enter its idle accept, matching a guide with no guests.
            try await Task.sleep(for: .milliseconds(100))
            transport.stop()
        }
    }

    @Test("Only a zero-byte challenge connection loss permits alternate-route admission", arguments: [0, 1, 102])
    func challengeConnectionFailureClassification(prefixLength: Int) throws {
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let client = ManagedSocket(fd: descriptors[0], generation: 0)
        defer { client.close(); Darwin.close(descriptors[1]) }
        if prefixLength > 0 {
            let prefix = Data(repeating: 0x47, count: prefixLength)
            let sent = prefix.withUnsafeBytes { send(descriptors[1], $0.baseAddress, prefix.count, 0) }
            try #require(sent == prefix.count)
        }
        try #require(shutdown(descriptors[1], SHUT_WR) == 0)
        do {
            _ = try RoomAdmissionTransport.readChallenge(client)
            Issue.record("Incomplete challenge was accepted")
        } catch {
            #expect((error is RoomAdmissionConnectionError) == (prefixLength == 0))
            if prefixLength > 0 { #expect(error is RoomAdmissionError) }
        }
    }

    @Test("A refused TCP admission connection is explicitly retryable over a matching nearby route")
    func refusedConnectionHasTransportFailureType() throws {
        let reserved = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(reserved >= 0)
        defer { Darwin.close(reserved) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        try #require(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(reserved, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reserved, $0, &size) }
        }
        try #require(named == 0)
        // The bound-but-not-listening socket reserves the port without a race with another listener.
        let client = RoomAdmissionTransport(port: UInt16(bigEndian: address.sin_port))
        #expect(throws: RoomAdmissionConnectionError.self) {
            try client.join(host: "127.0.0.1", sessionID: UUID(), expectedGuideID: UUID(), code: nil)
        }
    }

    @Test func fullSocketRejectsReplyWithoutWaiting() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { Darwin.close(sockets[0]); Darwin.close(sockets[1]) }
        let flags = fcntl(sockets[0], F_GETFL, 0)
        try #require(flags >= 0 && fcntl(sockets[0], F_SETFL, flags | O_NONBLOCK) == 0)
        let fill = Data(repeating: 1, count: 16_384)
        var blocked = false
        for _ in 0..<1_024 {
            let sent = fill.withUnsafeBytes { send(sockets[0], $0.baseAddress, fill.count, 0) }
            if sent < 0 {
                try #require(errno == EAGAIN || errno == EWOULDBLOCK)
                blocked = true; break
            }
        }
        try #require(blocked)
        let start = ContinuousClock.now
        #expect(throws: (any Error).self) {
            try RoomAdmissionTransport.writeReplyOnce(sockets[0], Data(repeating: 0, count: RoomAdmissionV2.replySize))
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test(arguments: [false, true])
    @MainActor
    func discoveryRoundtrip(locked: Bool) throws {
        let announce = BLECommand.ChannelAnnounce(channelID: UUID().uuidString, channelName: "Room",
            createdBy: UUID().uuidString, audioQuality: .standard, wifiSSID: nil, audioHostIP: "127.0.0.1",
            roomAdmissionVersion: 2, isRoomLocked: locked)
        let data = try JSONEncoder().encode(BLECommand.channelAnnounce(announce: announce))
        guard case let .channelAnnounce(decoded) = try JSONDecoder().decode(BLECommand.self, from: data) else {
            Issue.record("Discovery did not decode as channelAnnounce")
            return
        }
        #expect(decoded.roomAdmissionVersion == 2)
        #expect(decoded.isRoomLocked == locked)
        #expect(decoded.channelID == announce.channelID)
        let legacy = Data(#"{"channelAnnounce":{"channelID":"legacy","channelName":"Room","createdBy":"guide","audioQuality":"standard"}}"#.utf8)
        guard case let .channelAnnounce(old) = try JSONDecoder().decode(BLECommand.self, from: legacy) else {
            Issue.record("Legacy discovery rejected")
            return
        }
        #expect(old.roomAdmissionVersion == nil)
        #expect(old.isRoomLocked == nil)
    }

    @Test func lockEditUnlockPreservesMediaSecret() throws {
        let id = UUID()
        let guideID = UUID()
        let signer = GuideFrameSigner(sessionID: id, guideID: guideID)
        let transport = RoomAdmissionTransport(port: 56003)
        defer { transport.stop() }
        try transport.start(sessionID: id, sessionCode: "23456789AB", signer: signer)
        let admitted = try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: nil)
        #expect(admitted.mediaSecret == "23456789AB")
        #expect(admitted.guideIdentity.sessionID == id)
        #expect(admitted.guideIdentity.guideID == guideID)
        #expect(admitted.guideIdentity.publicKey == signer.publicKey)
        #expect(throws: (any Error).self) {
            try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: UUID(), code: nil)
        }
        try transport.update(policy: RoomAccessPolicy(sessionID: id, code: "1234"))
        #expect(throws: (any Error).self) { try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: nil) }
        do {
            _ = try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: "wrong")
            Issue.record("Wrong room code was admitted")
        } catch {
            #expect(!(error is RoomAdmissionConnectionError), "Guide rejection must never enable alternate-route fallback")
        }
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: "1234").guideIdentity == admitted.guideIdentity)
        try transport.update(policy: RoomAccessPolicy(sessionID: id, code: "Edited!"))
        #expect(throws: (any Error).self) { try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: "1234") }
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: "Edited!").mediaSecret == "23456789AB")
        try transport.update(policy: RoomAccessPolicy(sessionID: id, code: nil))
        #expect(try transport.join(host: "127.0.0.1", sessionID: id, expectedGuideID: guideID, code: nil).guideIdentity == admitted.guideIdentity)
    }
}
