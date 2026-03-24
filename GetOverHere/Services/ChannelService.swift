import Foundation
import os

@Observable
final class ChannelService {
    // MARK: - Channel State

    private(set) var channels: [Channel] = [.townsquare]
    var activeChannelID: String = Channel.townsquare.id
    private(set) var messagesByChannel: [String: [ChannelMessage]] = [:]

    // MARK: - Floor State (per channel)

    enum FloorState: Equatable {
        case idle
        case requesting
        case broadcasting
        case listening(speakerName: String)
    }

    private(set) var floorStateByChannel: [String: FloorState] = [:]

    // MARK: - File Transfers

    struct FileTransferState {
        let header: TransportMessage.FileHeader
        var receivedChunks: [Int: Data]
        var isComplete: Bool

        var progress: Double {
            guard header.fileSize > 0 else { return 0 }
            return Double(receivedChunks.count) / Double(max(1, totalExpectedChunks))
        }

        private var totalExpectedChunks: Int {
            // Estimate from first chunk or header
            let chunkSize = 16 * 1024 // 16KB per spec
            return max(1, (header.fileSize + chunkSize - 1) / chunkSize)
        }
    }

    private(set) var activeTransfers: [String: FileTransferState] = [:]

    // MARK: - Dependencies

    private let transport: any TransportProtocol
    private let audioEngine: AudioEngine
    private var captureTask: Task<Void, Never>?
    private var listenTasks: [Task<Void, Never>] = []

    // MARK: - Computed

    var activeFloorState: FloorState {
        floorStateByChannel[activeChannelID] ?? .idle
    }

    var activeMessages: [ChannelMessage] {
        messagesByChannel[activeChannelID] ?? []
    }

    var activeChannel: Channel? {
        channels.first { $0.id == activeChannelID }
    }

    // MARK: - Init

    init(transport: any TransportProtocol, audioEngine: AudioEngine) {
        self.transport = transport
        self.audioEngine = audioEngine
    }

    func startListening() {
        listenForTextMessages()
        listenForControlMessages()
        listenForAudio()
        listenForChannelAnnouncements()
        listenForFileHeaders()
        listenForFileChunks()
        listenForPeerEvents()
    }

    // MARK: - Channel Management

    func createChannel(name: String) {
        let channel = Channel(
            id: UUID().uuidString,
            name: name,
            createdAt: Date(),
            createdBy: transport.localPeer.id
        )
        guard !channels.contains(where: { $0.id == channel.id }) else { return }
        channels.append(channel)
        activeChannelID = channel.id
        broadcastChannelAnnounce(channel)
        Logger.channel.info("Created channel: \(name)")
    }

    func switchChannel(to channelID: String) {
        // Release floor if broadcasting in current channel
        if case .broadcasting = floorStateByChannel[activeChannelID] {
            releaseFloor()
        }
        activeChannelID = channelID
    }

    // MARK: - Messaging

    func sendMessage(_ content: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let payload = TransportMessage.TextPayload(
            channelID: activeChannelID,
            senderID: transport.localPeer.id,
            senderName: transport.localPeer.displayName,
            content: content
        )

        do {
            try transport.send(.text(payload), to: [])
        } catch {
            Logger.chat.error("Failed to send message: \(error.localizedDescription)")
            return
        }

        let message = ChannelMessage(
            id: payload.id,
            channelID: activeChannelID,
            senderID: payload.senderID,
            senderName: payload.senderName,
            content: content,
            timestamp: payload.timestamp,
            isFromMe: true
        )
        appendMessage(message)
    }

    // MARK: - Push to Talk

    func pushToTalk() {
        guard activeFloorState == .idle else { return }

        floorStateByChannel[activeChannelID] = .broadcasting

        let stream = audioEngine.startCapture()
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await data in stream {
                // Drop packets if we're falling behind — keeps audio real-time
                guard !Task.isCancelled else { break }
                do {
                    try self.transport.sendAudioData(data, to: [])
                } catch {
                    // Drop silently — audio is real-time, retrying is worse than dropping
                }
            }
        }

        let control = TransportMessage.WalkieTalkieControl.requestFloor(
            channelID: activeChannelID,
            peerID: transport.localPeer.id,
            peerName: transport.localPeer.displayName
        )
        sendControl(control)
        Logger.walkieTalkie.info("Broadcasting on active channel")
    }

    func releaseFloor() {
        guard case .broadcasting = floorStateByChannel[activeChannelID] else { return }

        audioEngine.stopCapture()
        captureTask?.cancel()
        captureTask = nil
        floorStateByChannel[activeChannelID] = .idle

        let control = TransportMessage.WalkieTalkieControl.releaseFloor(
            channelID: activeChannelID,
            peerID: transport.localPeer.id
        )
        sendControl(control)
        Logger.walkieTalkie.info("Released floor")
    }

    // MARK: - Private Helpers

    private func broadcastChannelAnnounce(_ channel: Channel) {
        let announce = TransportMessage.ChannelAnnounce(
            channelID: channel.id,
            channelName: channel.name,
            createdAt: channel.createdAt,
            createdBy: channel.createdBy
        )
        do {
            try transport.send(.channelAnnounce(announce), to: [])
        } catch {
            Logger.channel.error("Failed to broadcast channel announce: \(error.localizedDescription)")
        }
    }

    private func broadcastAllChannels() {
        for channel in channels {
            broadcastChannelAnnounce(channel)
        }
    }

    private func sendControl(_ control: TransportMessage.WalkieTalkieControl) {
        do {
            try transport.send(.walkieTalkieControl(control), to: [])
        } catch {
            Logger.walkieTalkie.error("Failed to send control: \(error.localizedDescription)")
        }
    }

    private func appendMessage(_ message: ChannelMessage) {
        if messagesByChannel[message.channelID] == nil {
            messagesByChannel[message.channelID] = []
        }
        messagesByChannel[message.channelID]?.append(message)
    }

    // MARK: - Listeners

    private func listenForTextMessages() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (payload, _) in self.transport.textMessages {
                let message = ChannelMessage(
                    id: payload.id,
                    channelID: payload.channelID,
                    senderID: payload.senderID,
                    senderName: payload.senderName,
                    content: payload.content,
                    timestamp: payload.timestamp,
                    isFromMe: false,
                    replyToID: payload.replyTo
                )
                self.appendMessage(message)
            }
        })
    }

    private func listenForControlMessages() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (control, _) in self.transport.controlMessages {
                self.handleControl(control)
            }
        })
    }

    private func listenForAudio() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (data, _) in self.transport.audioData {
                if case .listening = self.floorStateByChannel[self.activeChannelID] {
                    self.audioEngine.enqueuePlayback(data)
                }
            }
        })
    }

    private func listenForChannelAnnouncements() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (announce, _) in self.transport.channelAnnouncements {
                self.handleChannelAnnounce(announce)
            }
        })
    }

    private func listenForFileHeaders() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (header, _) in self.transport.fileHeaders {
                self.handleFileHeader(header)
            }
        })
    }

    private func listenForFileChunks() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await (chunk, _) in self.transport.fileChunks {
                self.handleFileChunk(chunk)
            }
        })
    }

    private func listenForPeerEvents() {
        listenTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.peerEvents {
                if case .connected = event {
                    self.broadcastAllChannels()
                }
            }
        })
    }

    // MARK: - Control Handling

    private func handleControl(_ control: TransportMessage.WalkieTalkieControl) {
        switch control {
        case .requestFloor(let channelID, _, let peerName):
            let current = floorStateByChannel[channelID] ?? .idle
            if current == .idle {
                floorStateByChannel[channelID] = .listening(speakerName: peerName)
                if channelID == activeChannelID {
                    audioEngine.startPlayback()
                }
                Logger.walkieTalkie.info("\(peerName) is speaking in channel")
            }

        case .releaseFloor(let channelID, _):
            if case .listening = floorStateByChannel[channelID] {
                floorStateByChannel[channelID] = .idle
                if channelID == activeChannelID {
                    audioEngine.stopPlayback()
                }
                Logger.walkieTalkie.info("Floor released in channel")
            }

        case .grantFloor, .denyFloor:
            break
        }
    }

    // MARK: - Channel Announce Handling

    private func handleChannelAnnounce(_ announce: TransportMessage.ChannelAnnounce) {
        guard !channels.contains(where: { $0.id == announce.channelID }) else { return }
        let channel = Channel(
            id: announce.channelID,
            name: announce.channelName,
            createdAt: announce.createdAt,
            createdBy: announce.createdBy
        )
        channels.append(channel)
        Logger.channel.info("Discovered channel: \(channel.name)")
    }

    // MARK: - File Transfer Handling

    private func handleFileHeader(_ header: TransportMessage.FileHeader) {
        activeTransfers[header.transferID] = FileTransferState(
            header: header,
            receivedChunks: [:],
            isComplete: false
        )
        var message = ChannelMessage(
            id: header.transferID,
            channelID: header.channelID,
            senderID: header.senderID,
            senderName: header.senderName,
            content: "",
            timestamp: header.timestamp,
            isFromMe: false
        )
        message.fileName = header.fileName
        message.fileSize = header.fileSize
        message.mimeType = header.mimeType
        appendMessage(message)
        Logger.fileShare.info("Receiving file: \(header.fileName) (\(header.fileSize) bytes)")
    }

    private func handleFileChunk(_ chunk: TransportMessage.FileChunk) {
        guard var transfer = activeTransfers[chunk.transferID] else { return }
        guard let data = Data(base64Encoded: chunk.data) else { return }
        transfer.receivedChunks[chunk.index] = data

        if transfer.receivedChunks.count == chunk.totalChunks {
            transfer.isComplete = true
            // Reassemble file
            var fullData = Data()
            for i in 0..<chunk.totalChunks {
                if let chunkData = transfer.receivedChunks[i] {
                    fullData.append(chunkData)
                }
            }
            // Save to disk
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dest = docs.appendingPathComponent("Received").appendingPathComponent(transfer.header.fileName)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fullData.write(to: dest)

            // Update message with local file path
            if var messages = messagesByChannel[transfer.header.channelID] {
                if let idx = messages.firstIndex(where: { $0.id == chunk.transferID }) {
                    messages[idx].localFilePath = dest.path
                    messagesByChannel[transfer.header.channelID] = messages
                }
            }
            Logger.fileShare.info("File complete: \(transfer.header.fileName)")
        }
        activeTransfers[chunk.transferID] = transfer
    }
}
