import Foundation
import SwiftUI

@Observable
final class AppCoordinator {
    let transport: CompositeTransport
    let channelService: ChannelService
    let audioEngine: AudioEngine

    // UI state
    var showSidebar = false
    var showCreateChannel = false
    var showMemberList = false
    var newChannelName = ""

    init(displayName: String) {
        let transport = CompositeTransport(displayName: displayName)
        let audioEngine = AudioEngine()

        self.transport = transport
        self.audioEngine = audioEngine
        self.channelService = ChannelService(transport: transport, audioEngine: audioEngine)
    }

    func start() {
        transport.start()
        channelService.startListening()
    }

    func stop() {
        transport.stop()
    }

    // MARK: - Bridge

    func toggleBridge() {
        if transport.isBridgeEnabled {
            transport.disableBridge()
        } else {
            transport.enableBridge()
        }
    }

    // MARK: - Channel Actions

    func createChannel() {
        let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32 else { return }
        channelService.createChannel(name: name)
        newChannelName = ""
        showCreateChannel = false
        showSidebar = false
    }
}
