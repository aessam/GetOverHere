import Foundation
import SwiftData
import os

@Observable
final class ChatService {
    private(set) var messagesByPeer: [String: [ChatMessage]] = [:]
    private let transport: any TransportProtocol
    private var modelContext: ModelContext?
    private var listenTask: Task<Void, Never>?

    init(transport: any TransportProtocol) {
        self.transport = transport
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadPersistedMessages()
        startListening()
    }

    func sendMessage(_ content: String, to peer: PeerInfo) {
        let payload = TransportMessage.TextPayload(
            senderID: transport.localPeer.id,
            senderName: transport.localPeer.displayName,
            content: content
        )

        do {
            try transport.send(.text(payload), to: [peer])
        } catch {
            Logger.chat.error("Failed to send message: \(error.localizedDescription)")
            return
        }

        let message = ChatMessage(
            id: payload.id,
            senderID: payload.senderID,
            senderName: payload.senderName,
            content: content,
            timestamp: payload.timestamp,
            isFromMe: true,
            peerID: peer.id
        )

        persist(message)
        appendMessage(message, for: peer.id)
        Logger.chat.info("Sent message to \(peer.displayName)")
    }

    func messages(for peerID: String) -> [ChatMessage] {
        messagesByPeer[peerID] ?? []
    }

    // MARK: - Private

    private func startListening() {
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (payload, peer) in self.transport.textMessages {
                let message = ChatMessage(
                    id: payload.id,
                    senderID: payload.senderID,
                    senderName: payload.senderName,
                    content: payload.content,
                    timestamp: payload.timestamp,
                    isFromMe: false,
                    peerID: peer.id
                )
                self.persist(message)
                self.appendMessage(message, for: peer.id)
                Logger.chat.info("Received message from \(peer.displayName)")
            }
        }
    }

    private func appendMessage(_ message: ChatMessage, for peerID: String) {
        if messagesByPeer[peerID] == nil {
            messagesByPeer[peerID] = []
        }
        messagesByPeer[peerID]?.append(message)
    }

    private func persist(_ message: ChatMessage) {
        modelContext?.insert(message)
        try? modelContext?.save()
    }

    private func loadPersistedMessages() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.timestamp)])
        guard let messages = try? context.fetch(descriptor) else { return }
        for message in messages {
            appendMessage(message, for: message.peerID)
        }
        Logger.chat.info("Loaded \(messages.count) persisted messages")
    }
}
