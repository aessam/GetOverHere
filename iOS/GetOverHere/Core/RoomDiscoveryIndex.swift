import Foundation

/// Merge public observations by room identity. LAN addresses never come from Bluetooth.
struct RoomDiscoveryIndex {
    enum Source { case lan, bluetooth }
    private var lan: [String: (BLECommand.ChannelAnnounce, PeerInfo)] = [:]
    private var bluetooth: [String: (BLECommand.ChannelAnnounce, PeerInfo)] = [:]
    var peers: [PeerInfo] {
        var result: [String: PeerInfo] = [:]
        for key in Set(lan.keys).union(bluetooth.keys) {
            if let entry = lan[key] ?? bluetooth[key] { result[entry.1.id] = entry.1 }
        }
        return Array(result.values)
    }
    mutating func update(_ value: BLECommand.ChannelAnnounce, peer: PeerInfo, source: Source) -> (BLECommand, PeerInfo)? {
        if source == .lan, value.audioHostIP?.isEmpty != false { return remove(value.channelID, source: .lan) }
        let key = UUID(uuidString: value.channelID)?.uuidString ?? value.channelID
        guard lan[key] != nil || bluetooth[key] != nil || Set(lan.keys).union(bluetooth.keys).count < 64 else { return nil }
        let entry = BLECommand.ChannelAnnounce(channelID: key, channelName: value.channelName,
            createdBy: value.createdBy, audioQuality: value.audioQuality, wifiSSID: nil,
            audioHostIP: source == .lan ? value.audioHostIP : nil,
            roomAdmissionVersion: value.roomAdmissionVersion, isRoomLocked: value.isRoomLocked)
        if source == .lan { lan[key] = (entry, peer) } else { bluetooth[key] = (entry, peer) }
        guard let selected = lan[key] ?? bluetooth[key] else { return nil }
        return (.channelAnnounce(announce: selected.0), selected.1)
    }
    mutating func remove(_ id: String, source: Source) -> (BLECommand, PeerInfo)? {
        let key = UUID(uuidString: id)?.uuidString ?? id
        let removed = source == .lan ? lan.removeValue(forKey: key) : bluetooth.removeValue(forKey: key)
        guard let removed else { return nil }
        if let selected = lan[key] ?? bluetooth[key] { return (.channelAnnounce(announce: selected.0), selected.1) }
        return (.channelUnavailable(channelID: key), removed.1)
    }
}
