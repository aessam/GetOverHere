import Foundation
import OSLog
import SwiftUI
import TourSessionCore

@Observable
final class AppCoordinator {
    let coordinator: NetworkCoordinator
    let channelService: ChannelService
    let audioEngine: AudioEngine
    let gateway: GatewaySessionCoordinator
    let packImporter: TourPackImporter
    let packLibrary: TourPackLibrary
    let preparedTours: PreparedTourStore
    var showPreparedTours = false
    /// Result of the last `.gohtour` import, shown once to the user.
    var packImportMessage: String?

    var showCreateChannel = false
    var showGateway = false
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
            self.packImporter = TourPackImporter(cache: cache)
            self.preparedTours = try PreparedTourStore(
                rootDirectory: applicationSupport.appending(path: "PreparedTours", directoryHint: .isDirectory)
            )
            self.packLibrary = try TourPackLibrary(
                fileURL: applicationSupport.appending(path: "ImportedTourPacks.json")
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
            guard let localControl = coordinator.controlPlane as? LocalControlPlane else {
                fatalError("Gateway requires the application's local control plane")
            }
            self.gateway = GatewaySessionCoordinator(service: channelService, control: localControl)
        } catch {
            fatalError("Tour feature storage setup failed: \(error.localizedDescription)")
        }
    }

    /// Opens a shared `.gohtour` pack (ADR-080): verifies it and stores each file under its hash so a
    /// later tour that names those hashes is ready without transferring them.
    func importTourPack(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let outcome = try await packImporter.importPack(at: url)
            try packLibrary.record(outcome.manifest)
            let files = outcome.imported + outcome.alreadyCached
            packImportMessage = "Tour ready: \(outcome.manifest.displayName) (\(files) files)"
        } catch {
            Logger.channel.error("Tour pack import failed (\(String(describing: error)))")
            packImportMessage = "This tour file could not be opened: \(error.localizedDescription)"
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
        gateway.stop()
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
