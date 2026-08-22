import SwiftUI

@main
struct GetOverHereApp: App {
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
        }
    }
}
