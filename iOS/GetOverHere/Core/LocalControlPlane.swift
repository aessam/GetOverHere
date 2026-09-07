import Foundation
import os
import TourSessionCore

/// Bonjour plus read-only Bluetooth room discovery. Only Bonjour supplies a join address.
/// Each live channel is advertised as a `_goh-audio._tcp` service and Bluetooth GOR1 metadata.
@Observable
final class LocalControlPlane: NSObject, ControlPlane, NearbyRouteControl {
    var onNearbyError: ((String) -> Void)?
    let localPeer: PeerInfo
    private(set) var connectedPeers: [PeerInfo] = []

    let commands: AsyncStream<(BLECommand, PeerInfo)>
    let peerEvents: AsyncStream<PeerEvent>

    private let commandCont: AsyncStream<(BLECommand, PeerInfo)>.Continuation
    private let peerCont: AsyncStream<PeerEvent>.Continuation

    private let browser = NetServiceBrowser()
    private var publishedServices: [String: NetService] = [:]
    private var discoveredServices: [String: NetService] = [:]
    private var peerByChannelID: [String: PeerInfo] = [:]
    private let bluetooth: any BluetoothRoomDiscoveryInterface
    private var discoveryIndex = RoomDiscoveryIndex()
    private var aware: (any NearbyRoomTransport)?
    private var awareRooms = Set<UUID>()
    private var hostedRecord: BluetoothRoomRecord?
    private let nearbyBridge = NearbySocketBridge()
    private var nearbyGuestRoom: UUID?
    private var routeAttempt: UInt64 = 0
    private(set) var usesBluetoothGuestRoute = false

    private static let serviceType = "_goh-audio._tcp."
    private static let audioPort = 50000
    private enum TXTKey {
        static let channelName = "chname"
        static let createdBy = "createdBy"
        static let creatorName = "crname"
        static let audioQuality = "quality"
        static let platform = "platform"
    }

    init(displayName: String, bluetooth: (any BluetoothRoomDiscoveryInterface)? = nil) {
        self.localPeer = PeerInfo(displayName: displayName, platform: .ios)
        self.bluetooth = bluetooth ?? BluetoothRoomDiscovery()
        (commands, commandCont) = AsyncStream.makeStream()
        (peerEvents, peerCont) = AsyncStream.makeStream()
        super.init()
        browser.delegate = self
        self.bluetooth.onRoom = { [weak self] record in
            guard let self, record.guideID != UUID(uuidString: self.localPeer.id) else { return }
            let peer = PeerInfo(id: record.guideID.uuidString, displayName: "Nearby guide",
                                platform: record.isAndroid ? .android : .ios)
            let value = BLECommand.ChannelAnnounce(channelID: record.roomID.uuidString,
                channelName: record.name, createdBy: peer.id, audioQuality: .standard,
                wifiSSID: nil, audioHostIP: nil, roomAdmissionVersion: 1, isRoomLocked: record.isLocked)
            self.emit(self.discoveryIndex.update(value, peer: peer, source: .bluetooth))
        }
        self.bluetooth.onLost = { [weak self] id in
            guard let self else { return }
            self.emit(self.discoveryIndex.remove(id.uuidString, source: .bluetooth))
        }
    }

    deinit {
        stop()
        commandCont.finish()
        peerCont.finish()
    }

    func start() {
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        Logger.transport.info("Local control plane started")
    }

    func setBluetoothDiscoveryMode(_ mode: BluetoothDiscoveryMode) {
        bluetooth.setMode(mode)
    }

    func setAwareDiscoveryMode(_ mode: BluetoothDiscoveryMode) {
        if aware == nil, mode != .off, #available(iOS 26.4, *) {
            let transport = WiFiAwareRoomTransport()
            transport.onError = { [weak self] message in self?.onNearbyError?(message) }
            transport.onRoom = { [weak self] record in
                guard let self, record.guideID != UUID(uuidString: localPeer.id) else { return }
                awareRooms.insert(record.roomID)
                let peer = PeerInfo(id: record.guideID.uuidString, displayName: "Nearby guide",
                                    platform: record.isAndroid ? .android : .ios)
                let announce = BLECommand.ChannelAnnounce(channelID: record.roomID.uuidString,
                    channelName: record.name, createdBy: peer.id, audioQuality: .standard,
                    roomAdmissionVersion: 1, isRoomLocked: record.isLocked)
                emit(discoveryIndex.update(announce, peer: peer, source: .aware))
            }
            transport.onLost = { [weak self] room in
                guard let self else { return }
                awareRooms.remove(room)
                emit(discoveryIndex.remove(room.uuidString, source: .aware))
            }
            aware = transport
        }
        aware?.publish(hostedRecord)
        aware?.setMode(mode)
    }

    func canConnectNearby(roomID: UUID) -> Bool {
        awareRooms.contains(roomID) || (bluetooth as? any BluetoothSessionDiscoveryInterface)?.canConnect(roomID: roomID) == true
    }

    func prepareNearbyGuest(roomID: UUID) async throws -> String {
        if let nearbyGuestRoom {
            guard nearbyGuestRoom == roomID else { throw NearbyConnectionError.rejected }
            return "127.0.0.1"
        }
        routeAttempt &+= 1
        let attempt = routeAttempt
        let connect: NearbySocketBridge.Connect
        if let aware, awareRooms.contains(roomID) {
            connect = { try await aware.connect(roomID: roomID) }
            usesBluetoothGuestRoute = false
        } else if let bluetooth = bluetooth as? any BluetoothSessionDiscoveryInterface, bluetooth.canConnect(roomID: roomID) {
            bluetooth.setJoinedRoom(roomID)
            connect = { try await bluetooth.connect(roomID: roomID) }
            usesBluetoothGuestRoute = true
        } else { throw NearbyConnectionError.unavailable }
        let host: String
        do { host = try await nearbyBridge.startGuest(roomID: roomID, connect: connect) }
        catch { if routeAttempt == attempt { stopNearbyGuest() }; throw error }
        guard routeAttempt == attempt else { throw CancellationError() }
        nearbyGuestRoom = roomID
        return host
    }

    func stopNearbyGuest() {
        routeAttempt &+= 1
        nearbyBridge.stop(); nearbyGuestRoom = nil
        if usesBluetoothGuestRoute { (bluetooth as? any BluetoothSessionDiscoveryInterface)?.setJoinedRoom(nil) }
        usesBluetoothGuestRoute = false
    }

    func stop() {
        stopNearbyGuest()
        aware?.stop()
        bluetooth.stop()
        discoveryIndex = RoomDiscoveryIndex()
        browser.stop()
        for service in publishedServices.values {
            service.stop()
        }
        for service in discoveredServices.values { service.stopMonitoring(); service.stop() }
        publishedServices.removeAll()
        discoveredServices.removeAll()
        peerByChannelID.removeAll()
        connectedPeers.removeAll()
        Logger.transport.info("Local control plane stopped")
    }

    func broadcast(_ command: BLECommand) {
        switch command {
        case .channelAnnounce(let announce):
            publishChannel(announce)
        case .channelEnded(let channelID):
            unpublishChannel(channelID: channelID)
        default:
            break
        }
    }

    func send(_ command: BLECommand, to peer: PeerInfo) {
        broadcast(command)
    }

    private func publishChannel(_ announce: BLECommand.ChannelAnnounce) {
        if let roomID = UUID(uuidString: announce.channelID), let guideID = UUID(uuidString: announce.createdBy) {
            let record = BluetoothRoomRecord(roomID: roomID, guideID: guideID, name: announce.channelName,
                isAndroid: false, isLocked: announce.isRoomLocked ?? true)
            hostedRecord = record
            bluetooth.publish(record)
            aware?.publish(record)
        }
        let txtData = NetService.data(fromTXTRecord: [
            TXTKey.channelName: Data(announce.channelName.utf8),
            TXTKey.createdBy: Data(announce.createdBy.utf8),
            TXTKey.creatorName: Data(localPeer.displayName.utf8),
            TXTKey.audioQuality: Data(announce.audioQuality.rawValue.utf8),
            TXTKey.platform: Data(localPeer.platform.rawValue.utf8),
            "admission": Data(String(announce.roomAdmissionVersion ?? 0).utf8),
            "locked": Data((announce.isRoomLocked == false ? "0" : "1").utf8)
        ])

        if let existing = publishedServices[announce.channelID] {
            existing.setTXTRecord(txtData)
            return
        }

        let service = NetService(domain: "local.", type: Self.serviceType, name: announce.channelID, port: Int32(Self.audioPort))
        service.delegate = self
        service.setTXTRecord(txtData)
        service.publish(options: NetService.Options.noAutoRename)
        publishedServices[announce.channelID] = service
        Logger.transport.info("Published local channel")
    }

    private func unpublishChannel(channelID: String) {
        hostedRecord = nil
        aware?.publish(nil)
        bluetooth.publish(nil)
        publishedServices.removeValue(forKey: channelID)?.stop()
        Logger.transport.info("Unpublished local channel")
    }

    private func registerPeer(_ peer: PeerInfo, channelID: String) {
        peerByChannelID[channelID] = peer
        guard !connectedPeers.contains(where: { $0.id == peer.id }) else { return }
        connectedPeers.append(peer)
        peerCont.yield(.connected(peer))
    }

    private func handleResolvedService(_ service: NetService) {
        guard let txtRaw = service.txtRecordData(),
              let txt = NetService.dictionary(fromTXTRecord: txtRaw) as? [String: Data],
              let channelName = txt[TXTKey.channelName].flatMap({ String(data: $0, encoding: .utf8) }),
              let createdBy = txt[TXTKey.createdBy].flatMap({ String(data: $0, encoding: .utf8) }),
              let creatorName = txt[TXTKey.creatorName].flatMap({ String(data: $0, encoding: .utf8) }),
              createdBy != localPeer.id else { return }

        let platformRaw = txt[TXTKey.platform].flatMap { String(data: $0, encoding: .utf8) } ?? PeerInfo.Platform.ios.rawValue
        let qualityRaw = txt[TXTKey.audioQuality].flatMap { String(data: $0, encoding: .utf8) } ?? AudioQuality.standard.rawValue
        let peer = PeerInfo(id: createdBy, displayName: creatorName, platform: PeerInfo.Platform(rawValue: platformRaw) ?? .ios)
        registerPeer(peer, channelID: service.name)
        Logger.transport.info("Resolved local channel")

        let announce = BLECommand.ChannelAnnounce(
            channelID: service.name,
            channelName: channelName,
            createdBy: createdBy,
            audioQuality: AudioQuality(rawValue: qualityRaw) ?? .standard,
            wifiSSID: nil,
            audioHostIP: ipv4Address(for: service),
            roomAdmissionVersion: txt["admission"].flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init),
            isRoomLocked: txt["locked"] != Data("0".utf8)
        )
        emit(discoveryIndex.update(announce, peer: peer, source: .lan))
    }

    private func emit(_ observation: (BLECommand, PeerInfo)?) {
        guard let observation else { return }
        connectedPeers = discoveryIndex.peers
        commandCont.yield(observation)
    }

    private func ipv4Address(for service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for addressData in addresses {
            let maybeIP: String? = addressData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return nil }
                let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)
                guard sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                let addrIn = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var addr = addrIn.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let maybeIP { return maybeIP }
        }
        return nil
    }
}

extension LocalControlPlane: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard publishedServices[service.name] == nil else { return }
        Logger.transport.info("Found local service")
        discoveredServices[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        discoveredServices.removeValue(forKey: service.name)?.stopMonitoring()
        if let peer = peerByChannelID.removeValue(forKey: service.name) {
            emit(discoveryIndex.remove(service.name, source: .lan))
            if !connectedPeers.contains(where: { $0.id == peer.id }) { peerCont.yield(.disconnected(peer)) }
        }
    }
}

extension LocalControlPlane: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        handleResolvedService(sender)
        sender.startMonitoring()
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        handleResolvedService(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        Logger.transport.error("Failed to resolve local service")
    }
}
