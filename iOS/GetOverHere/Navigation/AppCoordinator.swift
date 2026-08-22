import Foundation
import SwiftUI

@Observable
final class AppCoordinator {
    let coordinator: NetworkCoordinator
    let channelService: ChannelService
    let audioEngine: AudioEngine

    var showCreateChannel = false
    var newChannelName = ""

    init(displayName: String) {
        let coordinator = NetworkCoordinator(displayName: displayName)
        let audioEngine = AudioEngine()
        let applicationSupport: URL
        do {
            guard let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                fatalError("Application Support directory is unavailable")
            }
            applicationSupport = directory.appending(path: "GetOverHere", directoryHint: .isDirectory)
            let cache = try FileTourAssetCache(
                rootDirectory: applicationSupport.appending(path: "AssetCache", directoryHint: .isDirectory)
            )
            let contentStore = try TourContentStore(
                rootDirectory: applicationSupport.appending(path: "TourPacks", directoryHint: .isDirectory)
            )
            let tourControlService = TourControlService()
            let localGuidanceService = LocalGuidanceService()
            let assetTransferService = TourAssetTransferService(
                transport: LocalSessionAssetTransport(),
                cache: cache
            )

            self.coordinator = coordinator
            self.audioEngine = audioEngine
            self.channelService = ChannelService(
                coordinator: coordinator,
                audioEngine: audioEngine,
                tourControlService: tourControlService,
                assetTransferService: assetTransferService,
                contentStore: contentStore,
                localGuidanceService: localGuidanceService
            )
        } catch {
            fatalError("Tour feature storage setup failed: \(error.localizedDescription)")
        }
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
        channelService.createChannel(name: name)
        newChannelName = ""
        showCreateChannel = false
    }
}
