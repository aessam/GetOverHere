import SwiftUI

struct ChannelSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    private var service: ChannelService { coordinator.channelService }

    var body: some View {
        List(selection: Binding(
            get: { service.activeChannelID },
            set: { id in
                if let id, let ch = service.channels.first(where: { $0.id == id }) {
                    service.joinChannel(ch)
                }
            }
        )) {
            // Available megaphones
            if service.channels.isEmpty {
                emptyState
            } else {
                Section("Live Megaphones") {
                    ForEach(service.channels) { channel in
                        channelRow(channel)
                            .tag(channel.id)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.showCreateChannel = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 4) {
                    Circle().fill(coordinator.transport.connectedPeers.isEmpty ? .red : .green).frame(width: 8, height: 8)
                    Text("\(coordinator.transport.connectedPeers.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack {
            Image(systemName: channel.createdBy == coordinator.transport.localPeer.id
                ? "megaphone.fill" : "speaker.wave.2.fill")
                .foregroundStyle(service.activeChannelID == channel.id ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(channel.createdBy == coordinator.transport.localPeer.id ? "Your megaphone" : "Live")
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
