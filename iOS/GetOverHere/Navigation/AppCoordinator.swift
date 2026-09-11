import Foundation
import SwiftUI

@Observable
final class AppCoordinator {
    let coordinator: NetworkCoordinator
    let channelService: ChannelService
    let audioEngine: AudioEngine

    var showCreateChannel = false
    var newChannelName = ""
    var selectedTourFeature: TourFeature = .slides
    #if DEBUG
    var showDebugControl = false
    private(set) var debugControl: DebugAppControl?
    #endif

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
        #if DEBUG
        if debugControl == nil {
            let control = DebugAppControl(app: self)
            debugControl = control
            control.startIfRequested()
        }
        #endif
    }

    /// Termination path (FND-8): the session ends all three lanes before discovery and audio stop.
    func stop() {
        #if DEBUG
        debugControl?.stop()
        #endif
        channelService.terminate()
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
