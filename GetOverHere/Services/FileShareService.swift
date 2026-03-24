import Foundation
import os
import UniformTypeIdentifiers

@Observable
final class FileShareService {
    struct Transfer: Identifiable {
        let id = UUID()
        let fileName: String
        let peer: PeerInfo
        let direction: Direction
        var isComplete = false
        var localURL: URL?
        var errorDescription: String?
        var progress: Progress?

        enum Direction {
            case sending, receiving
        }
    }

    private(set) var activeTransfers: [Transfer] = []
    private(set) var receivedFiles: [Transfer] = []
    private let transport: any TransportProtocol
    private var listenTask: Task<Void, Never>?

    init(transport: any TransportProtocol) {
        self.transport = transport
        startListening()
    }

    func sendFile(at url: URL, to peer: PeerInfo) {
        let progress = transport.sendFile(at: url, named: url.lastPathComponent, to: peer)
        var transfer = Transfer(fileName: url.lastPathComponent, peer: peer, direction: .sending)
        transfer.progress = progress
        activeTransfers.append(transfer)
        Logger.fileShare.info("Sending file: \(url.lastPathComponent) to \(peer.displayName)")

        // Observe progress
        let transferID = transfer.id
        Task {
            while !progress.isFinished && !progress.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let index = activeTransfers.firstIndex(where: { $0.id == transferID }) {
                activeTransfers[index].isComplete = true
                if progress.isCancelled {
                    activeTransfers[index].errorDescription = "Cancelled"
                }
            }
        }
    }

    // MARK: - Private

    private func startListening() {
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.fileTransfers {
                self.handleFileEvent(event)
            }
        }
    }

    private func handleFileEvent(_ event: FileTransferEvent) {
        switch event {
        case .receiving(let name, let peer):
            let transfer = Transfer(fileName: name, peer: peer, direction: .receiving)
            activeTransfers.append(transfer)

        case .received(let name, let peer, let url):
            if let index = activeTransfers.firstIndex(where: {
                $0.fileName == name && $0.peer.id == peer.id && $0.direction == .receiving
            }) {
                activeTransfers[index].isComplete = true
                activeTransfers[index].localURL = url
                receivedFiles.append(activeTransfers[index])
                activeTransfers.remove(at: index)
            }
            Logger.fileShare.info("Received file: \(name) from \(peer.displayName)")

        case .failed(let name, let peer, let errorDesc):
            if let index = activeTransfers.firstIndex(where: {
                $0.fileName == name && $0.peer.id == peer.id
            }) {
                activeTransfers[index].errorDescription = errorDesc
            }
            Logger.fileShare.error("File transfer failed: \(name) — \(errorDesc)")
        }
    }
}
