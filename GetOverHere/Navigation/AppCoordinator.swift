import Foundation
import SwiftUI

@Observable
final class AppCoordinator {
    let transport: CompositeTransport
    let channelService: ChannelService
    let audioEngine: AudioEngine

    var showCreateChannel = false
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

    func toggleBridge() {
        if transport.isBridgeEnabled {
            transport.disableBridge()
        } else {
            transport.enableBridge()
        }
    }

    func createChannel() {
        let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        channelService.createChannel(name: name)
        newChannelName = ""
        showCreateChannel = false
    }
}
