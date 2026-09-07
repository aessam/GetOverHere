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
            Section {
                if #available(iOS 26.4, *) {
                    Toggle("Wi-Fi Aware (experimental)", isOn: Binding(
                        get: { service.awareDiscoveryEnabled }, set: { service.awareDiscoveryEnabled = $0 }))
                        .accessibilityIdentifier("awareRoomDiscovery")
                    if service.awareDiscoveryEnabled {
                        NearbyAwarePairingView(isGuide: service.isCreator)
                    }
                    if let error = service.nearbyError {
                        Text(error).foregroundStyle(.red).font(.caption)
                            .accessibilityIdentifier("nearbyTransportError")
                    }
                }
                Toggle("Bluetooth room discovery", isOn: Binding(
                    get: { service.bluetoothDiscoveryEnabled },
                    set: { service.bluetoothDiscoveryEnabled = $0 }))
                    .accessibilityIdentifier("bluetoothRoomDiscovery")
                Text("Experimental direct Bluetooth joining and audio. Keep Bluetooth enabled. Older app versions may provide discovery only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.activeChannelID == nil, service.connectionState == .failed,
               let error = service.tourFeatureError {
                Section("Could not start tour") {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("tourStartupError")
                }
            }
            // Available megaphones
            if service.channels.isEmpty {
                emptyState
            } else {
                Section("Live Megaphones") {
                    ForEach(service.channels) { channel in
                        Button {
                            guard service.activeChannelID != channel.id else { return }
                            if channel.roomAdmissionVersion == 1 && !channel.isRoomLocked {
                                service.joinChannel(channel, tourCode: "")
                                return
                            }
                            joinCode = ""
                            pendingJoinChannel = channel
                        } label: {
                            channelRow(channel)
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.canJoin(channel))
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
                    Section("Room Code") {
                        TextField("Code from your guide", text: $joinCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .fontDesign(.monospaced)
                    }
                    Section {
                        Text("This room is locked. Ask your guide for the code.")
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
                        .disabled(channel.roomAdmissionVersion == 1
                            ? !RoomAccessPolicy.isValidCode(joinCode)
                            : SessionCredential.normalize(joinCode).count != SessionCredential.shortCodeLength)
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
                Text(channel.createdBy == coordinator.coordinator.controlPlane.localPeer.id ? "Your megaphone"
                     : channel.audioHostIP == nil ? (service.canJoin(channel) ? "Nearby direct · Experimental" : "Nearby via Bluetooth · Audio unavailable") : "Live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if channel.isRoomLocked { Image(systemName: "lock.fill").accessibilityLabel("Locked room") }

            Circle()
                .fill(channel.audioHostIP == nil && channel.createdBy != service.localPeer.id ? .orange : .red)
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
            Text("Keep Bluetooth on and allow Bluetooth access to find nearby rooms. Create one to start broadcasting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}
