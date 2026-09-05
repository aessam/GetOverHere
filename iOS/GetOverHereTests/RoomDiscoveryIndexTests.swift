import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

@MainActor
struct RoomDiscoveryIndexTests {
    @Test func bluetoothCannotOverwriteLANAndLossFallsBack() throws {
        var index = RoomDiscoveryIndex()
        let peer = PeerInfo(displayName: "Guide")
        let id = UUID().uuidString
        let value = BLECommand.ChannelAnnounce(channelID: id.lowercased(), channelName: "Room", createdBy: peer.id,
            audioQuality: .standard, wifiSSID: nil, audioHostIP: "192.0.2.1", roomAdmissionVersion: 1, isRoomLocked: false)
        func address(_ result: (BLECommand, PeerInfo)?) throws -> String? {
            guard case let .channelAnnounce(announce) = try #require(result).0 else { throw TestFailure.invalid }
            #expect(announce.channelID == id)
            return announce.audioHostIP
        }
        #expect(try address(index.update(value, peer: peer, source: .bluetooth)) == nil)
        #expect(try address(index.update(value, peer: peer, source: .lan)) == "192.0.2.1")
        #expect(try address(index.update(value, peer: peer, source: .bluetooth)) == "192.0.2.1")
        #expect(index.peers.count == 1)
        #expect(try address(index.remove(id, source: .lan)) == nil)
        let removal = index.remove(id, source: .bluetooth)
        guard case let .channelUnavailable(removed) = try #require(removal).0 else {
            Issue.record("Room was not removed"); return
        }
        #expect(removed == id); #expect(index.peers.isEmpty)
    }
    @Test func bluetoothLossDoesNotRemoveLAN() throws {
        var index = RoomDiscoveryIndex()
        let peer = PeerInfo(displayName: "Guide")
        let value = BLECommand.ChannelAnnounce(channelID: UUID().uuidString, channelName: "Room", createdBy: peer.id,
            audioQuality: .standard, wifiSSID: nil, audioHostIP: "192.0.2.1")
        _ = index.update(value, peer: peer, source: .bluetooth)
        _ = index.update(value, peer: peer, source: .lan)
        let removal = index.remove(value.channelID, source: .bluetooth)
        guard case let .channelAnnounce(announce) = try #require(removal).0 else {
            Issue.record("LAN room removed by Bluetooth loss"); return
        }
        #expect(announce.audioHostIP == "192.0.2.1")
    }
    private enum TestFailure: Error { case invalid }

    @Test func unresolvedLANIsNotMislabelledAsBluetooth() {
        var index = RoomDiscoveryIndex()
        let peer = PeerInfo(displayName: "Guide")
        let value = BLECommand.ChannelAnnounce(channelID: UUID().uuidString, channelName: "Room", createdBy: peer.id,
            audioQuality: .standard, wifiSSID: nil, audioHostIP: nil)
        let observation = index.update(value, peer: peer, source: .lan)
        #expect(observation == nil)
        #expect(index.peers.isEmpty)
    }

    @Test func productionDiscoveryForwardsBluetoothMetadataWithoutAnAddress() async throws {
        let radio = DiscoveryRadio()
        let plane = LocalControlPlane(displayName: "Guest", bluetooth: radio)
        defer { plane.stop() }
        var iterator = plane.commands.makeAsyncIterator()
        let record = BluetoothRoomRecord(roomID: UUID(), guideID: UUID(), name: "Bluetooth room", isAndroid: true, isLocked: true)
        radio.onRoom?(record)
        let received = await iterator.next()
        guard case let .channelAnnounce(value) = try #require(received).0 else {
            Issue.record("Bluetooth observation did not reach production discovery"); return
        }
        #expect(value.channelID == record.roomID.uuidString)
        #expect(value.channelName == record.name)
        #expect(value.audioHostIP == nil)
        #expect(value.isRoomLocked == true)
    }

    private final class DiscoveryRadio: BluetoothRoomDiscoveryInterface {
        var onRoom: ((BluetoothRoomRecord) -> Void)?
        var onLost: ((UUID) -> Void)?
        var published: BluetoothRoomRecord?
        func start() {}
        func stop() {}
        func publish(_ record: BluetoothRoomRecord?) { published = record }
    }
}
