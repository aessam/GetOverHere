import SwiftUI
import SwiftData

@main
struct GetOverHereApp: App {
    @State private var coordinator: AppCoordinator

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ChatMessage.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        let deviceName = UIDevice.current.name
        _coordinator = State(initialValue: AppCoordinator(displayName: deviceName))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .modelContainer(sharedModelContainer)
                .onAppear {
                    coordinator.start(modelContext: sharedModelContainer.mainContext)
                }
        }
    }
}
