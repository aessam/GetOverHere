import SwiftUI

struct ChannelRootView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator
        NavigationSplitView {
            ChannelSidebar()
                .navigationTitle("Megaphone")
        } detail: {
            ChannelDetailView()
        }
        .alert("New Megaphone", isPresented: $coord.showCreateChannel) {
            TextField("Channel name", text: $coord.newChannelName)
            Button("Cancel", role: .cancel) { coordinator.newChannelName = "" }
            Button("Create") { coordinator.createChannel() }
        } message: {
            Text("Create a channel. You'll be the only speaker.")
        }
    }
}
