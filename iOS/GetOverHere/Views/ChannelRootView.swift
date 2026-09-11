import SwiftUI

struct ChannelRootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showWiFiAwareLab = false
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        @Bindable var coord = coordinator
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            ChannelSidebar(onOpenWiFiAwareLab: { showWiFiAwareLab = true })
                .navigationTitle("Megaphone")
        } detail: {
            ChannelDetailView()
        }
        .onChange(of: coordinator.channelService.activeChannelID) { _, activeChannelID in
            preferredCompactColumn = activeChannelID == nil ? .sidebar : .detail
        }
        .sheet(isPresented: $coord.showCreateChannel) {
            CreateChannelSheet()
        }
        #if DEBUG
        .sheet(isPresented: $coord.showDebugControl) {
            DebugControlPanel()
        }
        .onOpenURL { url in
            guard url.scheme == "goh-debug", url.host == "panel", url.path.isEmpty,
                  url.query == nil, url.fragment == nil else { return }
            coordinator.showDebugControl = true
        }
        #endif
        .sheet(isPresented: $showWiFiAwareLab) {
            if #available(iOS 26.4, *) {
                WiFiAwareLabView()
            } else {
                ContentUnavailableView(
                    "Wi-Fi Aware Unavailable",
                    systemImage: "wifi.slash",
                    description: Text("The experimental lab requires iOS 26.4 or later.")
                )
            }
        }
    }
}

struct CreateChannelSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var coord = coordinator
        NavigationStack {
            Form {
                Section("Channel Name") {
                    TextField("e.g., Tour Group, Lecture Hall", text: $coord.newChannelName)
                }

                Section {
                    Text("You'll be the only speaker. Everyone else listens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Megaphone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.newChannelName = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        coordinator.createChannel()
                        dismiss()
                    }
                    .disabled(coordinator.newChannelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
