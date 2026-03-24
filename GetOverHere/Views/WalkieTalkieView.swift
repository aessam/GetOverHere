import SwiftUI

struct WalkieTalkieView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var newChannelName = ""
    @State private var showingCreateChannel = false

    var body: some View {
        @Bindable var coord = coordinator
        NavigationStack(path: $coord.walkieTalkiePath) {
            Group {
                if let channel = coordinator.walkieTalkieService.currentChannel {
                    channelActiveView(channel)
                } else {
                    channelListView
                }
            }
            .navigationTitle("Walkie-Talkie")
            .toolbar {
                if coordinator.walkieTalkieService.currentChannel == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingCreateChannel = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .alert("New Channel", isPresented: $showingCreateChannel) {
                TextField("Channel Name", text: $newChannelName)
                Button("Create") {
                    guard !newChannelName.isEmpty else { return }
                    coordinator.walkieTalkieService.createChannel(name: newChannelName)
                    newChannelName = ""
                }
                Button("Cancel", role: .cancel) {
                    newChannelName = ""
                }
            }
        }
    }

    // MARK: - Channel List

    private var channelListView: some View {
        List {
            if coordinator.walkieTalkieService.channels.isEmpty && coordinator.transport.connectedPeers.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "waveform")
                } description: {
                    Text("Connect to peers and create a channel to start a walkie-talkie session")
                }
            } else {
                if !coordinator.walkieTalkieService.channels.isEmpty {
                    Section("Available Channels") {
                        ForEach(coordinator.walkieTalkieService.channels) { channel in
                            Button {
                                coordinator.walkieTalkieService.joinChannel(channel)
                            } label: {
                                HStack {
                                    Image(systemName: "waveform.circle.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading) {
                                        Text(channel.name)
                                            .font(.headline)
                                        Text("\(channel.memberIDs.count) members")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Join")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Quick Start") {
                    Button {
                        let name = "Channel \(coordinator.walkieTalkieService.channels.count + 1)"
                        coordinator.walkieTalkieService.createChannel(name: name)
                    } label: {
                        Label("Create New Channel", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    // MARK: - Active Channel

    private func channelActiveView(_ channel: Channel) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Channel info
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)
                Text(channel.name)
                    .font(.title2.bold())
                Text("\(channel.memberIDs.count) members")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Audio output toggle
            Toggle(isOn: Bindable(coordinator.audioEngine).useEarpiece) {
                Label(
                    coordinator.audioEngine.useEarpiece ? "Earpiece" : "Speaker",
                    systemImage: coordinator.audioEngine.useEarpiece ? "ear" : "speaker.wave.2"
                )
                .font(.subheadline)
            }
            .toggleStyle(.button)
            .tint(coordinator.audioEngine.useEarpiece ? .orange : .blue)
            .padding(.horizontal, 40)

            // Floor state indicator
            floorStateIndicator

            Spacer()

            // Push-to-Talk button
            pushToTalkButton

            // Leave button
            Button("Leave Channel", role: .destructive) {
                coordinator.walkieTalkieService.leaveChannel()
            }
            .padding(.bottom, 32)
        }
        .padding()
    }

    @ViewBuilder
    private var floorStateIndicator: some View {
        switch coordinator.walkieTalkieService.floorState {
        case .idle:
            Text("Tap to talk, tap again to stop")
                .foregroundStyle(.secondary)
        case .requesting:
            HStack {
                ProgressView()
                Text("Requesting floor...")
            }
        case .broadcasting:
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                Text("You are speaking")
                    .foregroundStyle(.red)
                    .font(.headline)
            }
        case .listening(let speakerName):
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.blue)
                Text("\(speakerName) is speaking")
                    .foregroundStyle(.blue)
                    .font(.headline)
            }
        }
    }

    private var pushToTalkButton: some View {
        let isBroadcasting = coordinator.walkieTalkieService.floorState == .broadcasting
        let isListening: Bool = {
            if case .listening = coordinator.walkieTalkieService.floorState { return true }
            return false
        }()

        return Circle()
            .fill(isBroadcasting ? Color.red : (isListening ? Color.blue.opacity(0.3) : Color.blue))
            .frame(width: 120, height: 120)
            .overlay {
                Image(systemName: isBroadcasting ? "mic.fill" : "mic")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            }
            .shadow(color: isBroadcasting ? .red.opacity(0.5) : .clear, radius: 20)
            .scaleEffect(isBroadcasting ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isBroadcasting)
            .onTapGesture {
                if isBroadcasting {
                    coordinator.walkieTalkieService.releaseFloor()
                } else if coordinator.walkieTalkieService.floorState == .idle {
                    coordinator.walkieTalkieService.pushToTalk()
                }
            }
            .disabled(isListening)
    }
}
