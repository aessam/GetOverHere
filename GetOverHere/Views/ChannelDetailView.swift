import SwiftUI

struct ChannelDetailView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var messageText = ""
    @State private var scrollToBottom = false

    private var service: ChannelService { coordinator.channelService }

    var body: some View {
        VStack(spacing: 0) {
            // Speaking banner
            speakingBanner

            // Message list
            messageList

            Divider()

            // Compose bar
            composeBar

            Divider()

            // Status bar
            statusBar
        }
        .navigationTitle(service.activeChannel?.name ?? "Townsquare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.showMemberList = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                        Text("\(coordinator.transport.connectedPeers.count + 1)")
                    }
                    .font(.subheadline)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { coordinator.showMemberList },
            set: { coordinator.showMemberList = $0 }
        )) {
            memberListSheet
        }
    }

    // MARK: - Speaking Banner

    @ViewBuilder
    private var speakingBanner: some View {
        if case .listening(let name) = service.activeFloorState {
            HStack {
                Image(systemName: "mic.fill")
                Text("\(name) is speaking...")
            }
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.15))
            .transition(.opacity)
        } else if case .broadcasting = service.activeFloorState {
            HStack {
                Image(systemName: "mic.fill")
                Text("You are speaking")
            }
            .font(.subheadline)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.red.opacity(0.15))
            .transition(.opacity)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if service.activeMessages.isEmpty {
                        emptyChannelState
                    } else {
                        ForEach(service.activeMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }

                    // Audio indicator at bottom when someone is speaking
                    if case .listening(let name) = service.activeFloorState {
                        audioIndicator(name: name)
                    } else if case .broadcasting = service.activeFloorState {
                        audioIndicator(name: "You", isSelf: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: service.activeMessages.count) {
                if let lastID = service.activeMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyChannelState: some View {
        ContentUnavailableView {
            Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Be the first to say something in #\(service.activeChannel?.name ?? "Townsquare")")
        }
        .padding(.top, 60)
    }

    // MARK: - Audio Indicator

    private func audioIndicator(name: String, isSelf: Bool = false) -> some View {
        HStack {
            Image(systemName: isSelf ? "waveform" : "speaker.wave.3.fill")
            Text("\(name) \(isSelf ? "are" : "is") speaking...")
                .font(.subheadline)
        }
        .foregroundStyle(isSelf ? .red : .orange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background((isSelf ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Compose Bar

    private var composeBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Attach button (placeholder — no file picker wired yet)
                Button {
                    // TODO: Photo/file picker
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }

                TextField("Type a message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit {
                        sendMessage()
                    }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // PTT button
            pttButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - PTT Button

    private var pttButton: some View {
        Button {
            switch service.activeFloorState {
            case .idle:
                service.pushToTalk()
            case .broadcasting:
                service.releaseFloor()
            default:
                break
            }
        } label: {
            HStack {
                switch service.activeFloorState {
                case .idle:
                    Image(systemName: "mic")
                    Text("Push to Talk")
                case .broadcasting:
                    Image(systemName: "mic.fill")
                    Text("Tap to Stop")
                case .listening(let name):
                    Image(systemName: "speaker.wave.3.fill")
                    Text("\(name) speaking")
                case .requesting:
                    ProgressView()
                    Text("Requesting...")
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(pttColor, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(service.activeFloorState == .requesting || isListening)
    }

    private var isListening: Bool {
        if case .listening = service.activeFloorState { return true }
        return false
    }

    private var pttColor: Color {
        switch service.activeFloorState {
        case .idle: .blue
        case .broadcasting: .red
        case .listening: .gray
        case .requesting: .blue
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 0) {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(coordinator.transport.connectedPeers.isEmpty ? .red : .green)
                    .frame(width: 8, height: 8)
                Text("D:\(coordinator.transport.discoveredPeers.count) C:\(coordinator.transport.connectedPeers.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                coordinator.toggleBridge()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: coordinator.transport.isBridgeEnabled
                        ? "antenna.radiowaves.left.and.right.circle.fill"
                        : "antenna.radiowaves.left.and.right.circle")
                    Text("Bridge")
                        .font(.caption)
                    if coordinator.transport.isBridgeEnabled {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    coordinator.transport.isBridgeEnabled ? Color.green.opacity(0.15) : Color.clear,
                    in: Capsule()
                )
            }
            .tint(coordinator.transport.isBridgeEnabled ? .green : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // VStack
    }

    // MARK: - Member List

    private var memberListSheet: some View {
        NavigationStack {
            List {
                // Local peer
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(coordinator.transport.localPeer.displayName)
                    Spacer()
                    Text("(you)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Connected peers
                ForEach(coordinator.transport.connectedPeers) { peer in
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(peer.displayName)
                    }
                }
            }
            .navigationTitle("Members (\(coordinator.transport.connectedPeers.count + 1))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        coordinator.showMemberList = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        service.sendMessage(text)
        messageText = ""
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChannelMessage

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                // Sender name (others only)
                if !message.isFromMe {
                    Text(message.senderName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Content
                if let fileName = message.fileName {
                    fileBubble(fileName: fileName)
                } else {
                    textBubble
                }

                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
    }

    private var textBubble: some View {
        Text(message.content)
            .font(.body)
            .foregroundStyle(message.isFromMe ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.isFromMe ? Color.accentColor : Color(.systemGray5),
                in: RoundedRectangle(cornerRadius: 16)
            )
    }

    private func fileBubble(fileName: String) -> some View {
        HStack {
            Image(systemName: fileIcon(for: message.mimeType))
                .font(.title2)
                .foregroundStyle(fileIconColor(for: message.mimeType))
            VStack(alignment: .leading) {
                Text(fileName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = message.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 280)
        .background(
            message.isFromMe ? Color.accentColor : Color(.systemGray5),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private func fileIcon(for mimeType: String?) -> String {
        guard let mime = mimeType else { return "doc.fill" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        if mime.contains("zip") || mime.contains("tar") { return "doc.zipper" }
        return "doc.fill"
    }

    private func fileIconColor(for mimeType: String?) -> Color {
        guard let mime = mimeType else { return .secondary }
        if mime.hasPrefix("image/") { return .blue }
        if mime.hasPrefix("audio/") { return .orange }
        if mime.hasPrefix("video/") { return .purple }
        if mime == "application/pdf" { return .red }
        if mime.hasPrefix("text/") { return .gray }
        if mime.contains("zip") || mime.contains("tar") { return .yellow }
        return .secondary
    }
}
