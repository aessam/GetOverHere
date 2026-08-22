import SwiftUI
import TourSessionCore

struct ChannelSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var pendingJoinChannel: Channel?
    @State private var joinCode = ""
    let onOpenWiFiAwareLab: () -> Void
    private var service: ChannelService { coordinator.channelService }

    var body: some View {
        List {
            // Available megaphones
            if service.channels.isEmpty {
                emptyState
            } else {
                Section("Live Megaphones") {
                    ForEach(service.channels) { channel in
                        Button {
                            guard service.activeChannelID != channel.id else { return }
                            joinCode = ""
                            pendingJoinChannel = channel
                        } label: {
                            channelRow(channel)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Wi-Fi Aware Lab", systemImage: "antenna.radiowaves.left.and.right", action: onOpenWiFiAwareLab)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.showCreateChannel = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(item: $pendingJoinChannel) { channel in
            NavigationStack {
                Form {
                    Section("Tour Code") {
                        TextField("10-character code", text: $joinCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .fontDesign(.monospaced)
                    }
                    Section {
                        Text("Ask the guide for the code shown on their screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(channel.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { pendingJoinChannel = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Join") {
                            service.joinChannel(channel, tourCode: joinCode)
                            pendingJoinChannel = nil
                        }
                        .disabled(SessionCredential.normalize(joinCode).count != SessionCredential.shortCodeLength)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack {
            Image(systemName: channel.createdBy == coordinator.coordinator.controlPlane.localPeer.id
                ? "megaphone.fill" : "speaker.wave.2.fill")
                .foregroundStyle(service.activeChannelID == channel.id ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(channel.createdBy == coordinator.coordinator.controlPlane.localPeer.id ? "Your megaphone" : "Live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "megaphone")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No megaphones nearby")
                .font(.headline)
            Text("Create one to start broadcasting")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}
