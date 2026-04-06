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
        .sheet(isPresented: $coord.showCreateChannel) {
            CreateChannelSheet()
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

                Section("Audio Quality") {
                    Picker("Quality", selection: $coord.selectedQuality) {
                        ForEach(AudioQuality.allCases, id: \.self) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)

                    if coordinator.selectedQuality == .hd {
                        Label {
                            Text("HD requires WiFi. May not work over Bluetooth-only connections.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
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
