import SwiftUI

struct ChannelDetailView: View {
    @Environment(AppCoordinator.self) private var coordinator
    private var service: ChannelService { coordinator.channelService }

    var body: some View {
        if let channel = service.activeChannel {
            if service.isCreator {
                creatorView(channel)
            } else {
                listenerView(channel)
            }
        } else {
            noChannelView
        }
    }

    // MARK: - No Channel Selected

    private var noChannelView: some View {
        VStack(spacing: 16) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Create or join a megaphone")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Tap + to start broadcasting, or select a channel to listen")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Creator View (I'm the megaphone)

    private func creatorView(_ channel: Channel) -> some View {
        VStack(spacing: 32) {
            Spacer()

            // Big megaphone icon
            Image(systemName: "megaphone.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: service.listenState == .broadcasting)

            Text(channel.name)
                .font(.largeTitle.bold())

            Text("YOU ARE LIVE")
                .font(.headline)
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.red.opacity(0.15), in: Capsule())

            Text("\(service.listenerCount) listeners")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()

            // Status
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("D:\(coordinator.transport.discoveredPeers.count) C:\(coordinator.transport.connectedPeers.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // End broadcast
            Button(role: .destructive) {
                service.leaveChannel()
            } label: {
                Label("End Broadcast", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Listener View

    private func listenerView(_ channel: Channel) -> some View {
        VStack(spacing: 32) {
            Spacer()

            // Speaker icon
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
                .symbolEffect(.variableColor, isActive: service.listenState == .listening)

            Text(channel.name)
                .font(.largeTitle.bold())

            Text("Listening...")
                .font(.headline)
                .foregroundStyle(.blue)

            Text("by \(channel.createdBy == coordinator.transport.localPeer.id ? "you" : "someone nearby")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            // Status
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("D:\(coordinator.transport.discoveredPeers.count) C:\(coordinator.transport.connectedPeers.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // Leave
            Button {
                service.leaveChannel()
            } label: {
                Label("Leave Channel", systemImage: "arrow.left.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
