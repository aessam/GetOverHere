import Combine
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
                // FND-8: a terminating guide sends the authenticated leave and clears every lane.
                // Scene phase `.background` is deliberately not used: a backgrounded guide keeps broadcasting.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    coordinator.stop()
                }
        }
    }
}
