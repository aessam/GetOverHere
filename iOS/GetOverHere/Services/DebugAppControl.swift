#if DEBUG
import AppDebugControl
import Foundation
import Network
import OSLog
import TourSessionCore
import UIKit

/// Debug adapter for the real scene coordinator; never constructs a second app/service.
@MainActor
@Observable
final class DebugAppControl: DebugCommandHandler {
    private weak var app: AppCoordinator?
    private var server: DebugControlServer?
    private var previousIdleTimerDisabled: Bool?
    private(set) var state = "disabled"
    private(set) var addresses: [String] = []
    private(set) var port: UInt16?
    private let logger = Logger(subsystem: "com.aens.GetOverHere", category: "DebugControl")

    init(app: AppCoordinator) { self.app = app }

    func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard state == "disabled", environment["GOH_DEBUG_CONTROL"] == "1" else { return }
        do {
            guard let keyText = environment["GOH_DEBUG_CONTROL_KEY"], let key = Data(base64Encoded: keyText), key.count == 32,
                  let identityText = environment["GOH_DEBUG_CONTROL_IDENTITY"],
                  let bytes = Data(base64Encoded: identityText) else { throw DebugControlError.invalidKey }
            let identity = try DebugTLS.identity(pkcs12: bytes, password: keyText)
            let server = DebugControlServer(handler: self)
            self.server = server
            state = "starting"
            server.onState = { [weak self] state, port in
                guard let self else { return }
                if state != "connection-rejected" { self.state = state }
                self.port = port
                if state == "listening" { self.keepAwakeForDebugSession() }
                if state == "stopped" || state == "failed" { self.restoreIdleTimer() }
                self.addresses = Self.localAddresses()
                self.logger.notice("Debug control state: \(state, privacy: .public)")
                self.writeEndpointStatus()
            }
            try server.start(key: key, identity: identity)
        } catch {
            server?.stop()
            server = nil
            restoreIdleTimer()
            state = "configuration-failed"
            logger.error("Debug control requires a valid ephemeral key and in-memory identity")
            writeEndpointStatus()
        }
    }

    func stop() { server?.stop(); server = nil; restoreIdleTimer() }

    private func keepAwakeForDebugSession() {
        if previousIdleTimerDisabled == nil {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func restoreIdleTimer() {
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }

    func execute(_ request: DebugRequest) throws -> String {
        guard let app else { throw DebugControlError.closed }
        let service = app.channelService
        let allowed: [String: Set<String>] = [
            "status": [], "discover": [], "create": ["name"], "join": ["id", "code"],
            "leave": [], "cancel-join": [], "room-lock": ["locked", "code"],
            "feature": ["name"], "next-slide": [], "previous-slide": [],
            "retry-audio": [], "restart-microphone": [], "discovery": ["bluetooth", "aware"],
            "output": ["mode"], "show-create": [], "show-debug": [], "dismiss": [],
        ]
        guard let fields = allowed[request.command], Set(request.arguments.keys).isSubset(of: fields),
              request.arguments.values.allSatisfy({ $0.utf8.count <= 400 }) else { throw DebugControlError.rejected }
        if request.command != "status" {
            guard UIApplication.shared.applicationState == .active else { throw DebugControlError.rejected }
        }
        func argument(_ key: String) throws -> String {
            guard let value = request.arguments[key], !value.isEmpty else { throw DebugControlError.rejected }
            return value
        }
        func boolean(_ key: String) throws -> Bool {
            switch try argument(key) { case "true": true; case "false": false; default: throw DebugControlError.rejected }
        }
        switch request.command {
        case "status": break
        case "discover": service.findNearbyTours()
        case "create":
            let name = try argument("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 120, service.activeChannelID == nil,
                  service.connectionState != .connecting else { throw DebugControlError.rejected }
            app.newChannelName = name
            app.createChannel()
        case "join":
            let id = try argument("id")
            guard service.activeChannelID == nil, service.connectionState != .connecting,
                  let room = service.channels.first(where: { $0.id == id }), service.canJoin(room) else { throw DebugControlError.rejected }
            service.joinChannel(room, tourCode: request.arguments["code"] ?? "")
        case "leave": service.leaveChannel()
        case "cancel-join": service.cancelJoin()
        case "room-lock":
            guard service.isCreator else { throw DebugControlError.rejected }
            service.updateRoomAccess(locked: try boolean("locked"), code: request.arguments["code"] ?? "")
        case "feature":
            guard service.activeChannelID != nil, let feature = TourFeature(rawValue: try argument("name")) else { throw DebugControlError.rejected }
            app.selectedTourFeature = feature
        case "next-slide", "previous-slide":
            guard service.isCreator else { throw DebugControlError.rejected }
            if request.command == "next-slide" { service.nextSlide() } else { service.previousSlide() }
        case "retry-audio": service.retryAudio()
        case "restart-microphone":
            guard service.isCreator else { throw DebugControlError.rejected }
            service.restartMicrophone()
        case "discovery":
            let bluetooth = try boolean("bluetooth"), aware = try boolean("aware")
            guard service.activeChannelID == nil else { throw DebugControlError.rejected }
            service.bluetoothDiscoveryEnabled = bluetooth; service.awareDiscoveryEnabled = aware
        case "output":
            guard let output = ListenerOutput(rawValue: try argument("mode")) else { throw DebugControlError.rejected }
            service.setListenerOutput(output)
        case "show-create": app.showCreateChannel = true
        case "show-debug": app.showDebugControl = true
        case "dismiss": app.showCreateChannel = false; app.showDebugControl = false
        default: throw DebugControlError.rejected
        }
        return try snapshot()
    }

    func snapshot() throws -> String {
        guard let app else { throw DebugControlError.closed }
        let service = app.channelService
        let object: [String: Any] = [
            "screen": app.showDebugControl ? "debug" : app.showCreateChannel ? "create" : service.activeChannelID == nil ? "rooms" : "tour",
            "feature": app.selectedTourFeature.rawValue,
            "foreground": UIApplication.shared.applicationState == .active,
            "activeRoom": service.activeChannelID ?? "",
            "role": service.isCreator ? "guide" : service.activeChannelID == nil ? "none" : "guest",
            "connection": String(describing: service.connectionState),
            "audio": String(describing: service.audioRuntimeState),
            "joinStage": service.joinStage?.rawValue ?? "",
            "transport": service.guestRoute.map { String(describing: $0.transport) } ?? "",
            "audioReadyGuests": service.tourControlService.audioReadyGuestCount,
            "acceptedPlaybackBytes": app.audioEngine.acceptedPlaybackByteCount,
            "locked": service.isRoomLocked,
            "bluetooth": service.bluetoothDiscoveryEnabled, "aware": service.awareDiscoveryEnabled,
            "error": service.audioRuntimeError ?? service.tourFeatureError ?? service.roomAccessError ?? "",
            "nearbyError": service.nearbyError ?? "",
            "rooms": service.channels.prefix(64).map { room in
                ["id": room.id, "name": room.name, "locked": room.isRoomLocked,
                 "joinable": service.canJoin(room), "nearby": room.nearbyAvailable] as [String: Any]
            },
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func writeEndpointStatus() {
        do {
            let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = root.appending(path: "DebugControl", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["state": state, "addresses": addresses, "port": port.map(Int.init) ?? 0])
            try data.write(to: directory.appending(path: "endpoint.json"), options: [.atomic, .completeFileProtection])
        } catch { logger.error("Could not write debug endpoint status") }
    }

    private static func localAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var values: [String] = []
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.append(String(cString: host))
            }
        }
        return values.sorted()
    }
}
#endif
