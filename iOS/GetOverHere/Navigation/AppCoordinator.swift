import Foundation
import SwiftUI

@Observable
final class AppCoordinator {
    let coordinator: NetworkCoordinator
    let channelService: ChannelService
    let audioEngine: AudioEngine

    var showCreateChannel = false
    var newChannelName = ""
    var selectedQuality: AudioQuality = .standard

    init(displayName: String) {
        let coordinator = NetworkCoordinator(displayName: displayName)
        let audioEngine = AudioEngine()

        self.coordinator = coordinator
        self.audioEngine = audioEngine
        self.channelService = ChannelService(coordinator: coordinator, audioEngine: audioEngine)
    }

    func start() {
        coordinator.start()
        channelService.startListening()
    }

    func stop() {
        coordinator.stop()
    }

    func createChannel() {
        let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        channelService.audioQuality = selectedQuality
        channelService.createChannel(name: name)
        newChannelName = ""
        showCreateChannel = false
    }
}
