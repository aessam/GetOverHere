import Foundation

/// Merge public observations by room identity. LAN addresses never come from Bluetooth.
struct RoomDiscoveryIndex {
    enum Source { case lan, bluetooth, aware, applePeer }
    private var lan: [String: (BLECommand.ChannelAnnounce, PeerInfo)] = [:]
    private var bluetooth: [String: (BLECommand.ChannelAnnounce, PeerInfo)] = [:]
    private var aware: [String: (BLECommand.ChannelAnnounce, PeerInfo)] = [:]
    private var applePeer: [String: (BLECommand.ChannelAnnounce, PeerInfo)] = [:]
    var peers: [PeerInfo] {
        var result: [String: PeerInfo] = [:]
        for key in Set(lan.keys).union(bluetooth.keys).union(aware.keys).union(applePeer.keys) {
            if let entry = lan[key] ?? applePeer[key] ?? aware[key] ?? bluetooth[key] { result[entry.1.id] = entry.1 }
        }
        return Array(result.values)
    }
    mutating func update(_ value: BLECommand.ChannelAnnounce, peer: PeerInfo, source: Source) -> (BLECommand, PeerInfo)? {
        if source == .lan, value.audioHostIP?.isEmpty != false { return remove(value.channelID, source: .lan) }
        let key = UUID(uuidString: value.channelID)?.uuidString ?? value.channelID
        guard lan[key] != nil || bluetooth[key] != nil || aware[key] != nil || applePeer[key] != nil ||
                Set(lan.keys).union(bluetooth.keys).union(aware.keys).union(applePeer.keys).count < 64 else { return nil }
        let entry = BLECommand.ChannelAnnounce(channelID: key, channelName: value.channelName,
            createdBy: value.createdBy, audioQuality: value.audioQuality, wifiSSID: nil,
            audioHostIP: source == .lan ? value.audioHostIP : nil,
            roomAdmissionVersion: value.roomAdmissionVersion, isRoomLocked: value.isRoomLocked)
        switch source {
        case .lan: lan[key] = (entry, peer)
        case .bluetooth: bluetooth[key] = (entry, peer)
        case .aware: aware[key] = (entry, peer)
        case .applePeer: applePeer[key] = (entry, peer)
        }
        guard let selected = lan[key] ?? applePeer[key] ?? aware[key] ?? bluetooth[key] else { return nil }
        return (.channelAnnounce(announce: selected.0), selected.1)
    }
    mutating func remove(_ id: String, source: Source) -> (BLECommand, PeerInfo)? {
        let key = UUID(uuidString: id)?.uuidString ?? id
        let removed: (BLECommand.ChannelAnnounce, PeerInfo)?
        switch source {
        case .lan: removed = lan.removeValue(forKey: key)
        case .bluetooth: removed = bluetooth.removeValue(forKey: key)
        case .aware: removed = aware.removeValue(forKey: key)
        case .applePeer: removed = applePeer.removeValue(forKey: key)
        }
        guard let removed else { return nil }
        if let selected = lan[key] ?? applePeer[key] ?? aware[key] ?? bluetooth[key] { return (.channelAnnounce(announce: selected.0), selected.1) }
        return (.channelUnavailable(channelID: key), removed.1)
    }
}
