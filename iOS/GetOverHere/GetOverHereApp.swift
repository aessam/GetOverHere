import Combine
import SwiftUI

@main
struct GetOverHereApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: AppCoordinator

    init() {
        let deviceName = UIDevice.current.model
        _coordinator = State(initialValue: AppCoordinator(displayName: deviceName))
    }

    var body: some Scene {
        WindowGroup {
            ChannelRootView()
                .environment(coordinator)
                .onAppear {
                    coordinator.start()
                }
                // FND-8: a terminating guide sends the authenticated leave and clears every lane.
                // Stop only the foreground discovery preview; LAN audio keeps broadcasting.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { coordinator.channelService.discoveryForeground = false }
                    if phase == .active { coordinator.channelService.discoveryForeground = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    coordinator.stop()
                }
        }
    }
}
