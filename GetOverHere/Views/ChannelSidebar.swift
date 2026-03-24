import SwiftUI

struct ChannelSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator

    private var service: ChannelService { coordinator.channelService }

    var body: some View {
        List(selection: Binding(
            get: { service.activeChannelID },
            set: { newID in
                if let id = newID {
                    service.switchChannel(to: id)
                }
            }
        )) {
            // Bridge banner
            if coordinator.transport.isBridgeEnabled {
                bridgeBanner
            }

            // Townsquare (pinned)
            if let townsquare = service.channels.first(where: { $0.id == Channel.townsquare.id }) {
                channelRow(townsquare, icon: "star.circle.fill")
                    .tag(townsquare.id)
            }

            // User-created channels sorted by name
            let userChannels = service.channels
                .filter { $0.id != Channel.townsquare.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            ForEach(userChannels) { channel in
                channelRow(channel, icon: "number.circle.fill")
                    .tag(channel.id)
            }

            // Empty state
            if userChannels.isEmpty {
                emptyState
            }

            // Create channel button
            Button {
                coordinator.showCreateChannel = true
            } label: {
                Label("New Channel", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Channel Row

    private func channelRow(_ channel: Channel, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(service.activeChannelID == channel.id ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body.bold())
                    .lineLimit(1)

                if let lastMessage = service.messagesByChannel[channel.id]?.last {
                    Text(lastMessage.content.isEmpty ? lastMessage.fileName ?? "" : lastMessage.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("(\(coordinator.transport.connectedPeers.count + 1))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Bridge Banner

    private var bridgeBanner: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("Bridging")
                    .font(.subheadline.bold())
                // BLE peers can be counted from composite transport
                Text("Listening for Android devices...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.green.opacity(0.3), lineWidth: 1))
        .listRowSeparator(.hidden)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "megaphone")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Create a channel")
                .font(.headline)
            Text("Organize your conversations by topic.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }
}
