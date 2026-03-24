import SwiftUI

struct NearbyView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            List {
                connectedSection
                discoveredSection
            }
            .navigationTitle("Nearby")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    localPeerBadge
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var connectedSection: some View {
        if !coordinator.transport.connectedPeers.isEmpty {
            Section("Connected") {
                ForEach(coordinator.transport.connectedPeers) { peer in
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.green)
                        Text(peer.displayName)
                        Spacer()
                        Button("Chat") {
                            coordinator.navigateToChat(with: peer)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredSection: some View {
        Section("Discovered") {
            if coordinator.transport.discoveredPeers.isEmpty {
                ContentUnavailableView {
                    Label("Searching...", systemImage: "magnifyingglass")
                } description: {
                    Text("Looking for nearby devices running GetOverHere")
                }
            } else {
                ForEach(coordinator.transport.discoveredPeers) { peer in
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        Text(peer.displayName)
                        Spacer()
                        Button("Connect") {
                            coordinator.transport.invitePeer(peer)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var localPeerBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            Text(coordinator.transport.localPeer.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
