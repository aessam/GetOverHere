import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showingPicker = false
    @State private var selectedPeer: PeerInfo?
    @State private var showingPeerSheet = false

    var body: some View {
        NavigationStack {
            List {
                sendSection
                activeTransfersSection
                receivedFilesSection
            }
            .navigationTitle("Files")
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFilePicked(result)
            }
        }
    }

    // MARK: - Sections

    private var sendSection: some View {
        Section {
            if coordinator.transport.connectedPeers.isEmpty {
                ContentUnavailableView {
                    Label("No Peers", systemImage: "doc.on.doc")
                } description: {
                    Text("Connect to nearby devices to share files")
                }
            } else {
                ForEach(coordinator.transport.connectedPeers) { peer in
                    Button {
                        selectedPeer = peer
                        showingPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Send to \(peer.displayName)")
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Send File")
        }
    }

    @ViewBuilder
    private var activeTransfersSection: some View {
        if !coordinator.fileShareService.activeTransfers.isEmpty {
            Section("Active Transfers") {
                ForEach(coordinator.fileShareService.activeTransfers) { transfer in
                    HStack {
                        Image(systemName: transfer.direction == .sending ? "arrow.up.doc" : "arrow.down.doc")
                            .foregroundStyle(transfer.direction == .sending ? .orange : .blue)
                        VStack(alignment: .leading) {
                            Text(transfer.fileName)
                                .font(.subheadline)
                            Text(transfer.direction == .sending ? "Sending to \(transfer.peer.displayName)" : "Receiving from \(transfer.peer.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if transfer.errorDescription != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var receivedFilesSection: some View {
        if !coordinator.fileShareService.receivedFiles.isEmpty {
            Section("Received Files") {
                ForEach(coordinator.fileShareService.receivedFiles) { transfer in
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text(transfer.fileName)
                                .font(.subheadline)
                            Text("From \(transfer.peer.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = transfer.localURL {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - File Handling

    private func handleFilePicked(_ result: Result<[URL], Error>) {
        guard let peer = selectedPeer,
              case .success(let urls) = result,
              let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Copy to temp location for sending
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.copyItem(at: url, to: temp)

        coordinator.fileShareService.sendFile(at: temp, to: peer)
    }
}
