import SwiftUI

struct ChannelRootView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator
        NavigationSplitView(columnVisibility: .constant(.automatic)) {
            ChannelSidebar()
                .navigationTitle("Channels")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            coordinator.showCreateChannel = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                    }
                }
        } detail: {
            ChannelDetailView()
        }
        .alert("New Channel", isPresented: $coord.showCreateChannel) {
            TextField("Channel name", text: $coord.newChannelName)
            Button("Cancel", role: .cancel) {
                coordinator.newChannelName = ""
            }
            Button("Create") {
                coordinator.createChannel()
            }
            .disabled(coordinator.newChannelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for the new channel (max 32 characters).")
        }
    }
}
