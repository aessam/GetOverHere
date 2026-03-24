import SwiftUI

struct ChatListView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator
        NavigationStack(path: $coord.chatPath) {
            List {
                if coordinator.transport.connectedPeers.isEmpty {
                    ContentUnavailableView {
                        Label("No Peers", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Connect to nearby devices in the Nearby tab to start chatting")
                    }
                } else {
                    ForEach(coordinator.transport.connectedPeers) { peer in
                        NavigationLink(value: ChatRoute.room(peer)) {
                            HStack {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(peer.displayName)
                                        .font(.headline)
                                    let messages = coordinator.chatService.messages(for: peer.id)
                                    if let last = messages.last {
                                        Text(last.content)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text("No messages yet")
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .room(let peer):
                    ChatRoomView(peer: peer)
                }
            }
        }
    }
}
