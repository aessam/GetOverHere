package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.*
import kotlinx.coroutines.flow.*
import java.io.File

class MockTransport(
    displayName: String = "TestDevice"
) : TransportProtocol {

    override val localPeer = PeerInfo(id = "local-test-id", displayName = displayName)

    private val _discoveredPeers = MutableStateFlow<List<PeerInfo>>(emptyList())
    override val discoveredPeers: StateFlow<List<PeerInfo>> = _discoveredPeers.asStateFlow()

    private val _connectedPeers = MutableStateFlow<List<PeerInfo>>(emptyList())
    override val connectedPeers: StateFlow<List<PeerInfo>> = _connectedPeers.asStateFlow()

    private val _textMessages = MutableSharedFlow<Pair<TextPayload, PeerInfo>>(extraBufferCapacity = 64)
    override val textMessages: SharedFlow<Pair<TextPayload, PeerInfo>> = _textMessages.asSharedFlow()

    private val _controlMessages = MutableSharedFlow<Pair<WalkieTalkieControlType, PeerInfo>>(extraBufferCapacity = 64)
    override val controlMessages: SharedFlow<Pair<WalkieTalkieControlType, PeerInfo>> = _controlMessages.asSharedFlow()

    private val _channelAnnounces = MutableSharedFlow<Pair<ChannelAnnouncePayload, PeerInfo>>(extraBufferCapacity = 64)
    override val channelAnnounces: SharedFlow<Pair<ChannelAnnouncePayload, PeerInfo>> = _channelAnnounces.asSharedFlow()

    private val _fileHeaders = MutableSharedFlow<Pair<FileHeaderPayload, PeerInfo>>(extraBufferCapacity = 64)
    override val fileHeaders: SharedFlow<Pair<FileHeaderPayload, PeerInfo>> = _fileHeaders.asSharedFlow()

    private val _fileChunks = MutableSharedFlow<Pair<FileChunkPayload, PeerInfo>>(extraBufferCapacity = 256)
    override val fileChunks: SharedFlow<Pair<FileChunkPayload, PeerInfo>> = _fileChunks.asSharedFlow()

    private val _audioData = MutableSharedFlow<Pair<ByteArray, PeerInfo>>(extraBufferCapacity = 256)
    override val audioData: SharedFlow<Pair<ByteArray, PeerInfo>> = _audioData.asSharedFlow()

    private val _fileTransfers = MutableSharedFlow<FileTransferEvent>(extraBufferCapacity = 16)
    override val fileTransfers: SharedFlow<FileTransferEvent> = _fileTransfers.asSharedFlow()

    private val _peerEvents = MutableSharedFlow<PeerEventData>(extraBufferCapacity = 32)
    override val peerEvents: SharedFlow<PeerEventData> = _peerEvents.asSharedFlow()

    // --- Captured sends for assertions ---
    val sentMessages = mutableListOf<TransportMessage>()
    val sentAudioData = mutableListOf<ByteArray>()

    override fun start() {}
    override fun stop() {}
    override fun invitePeer(peer: PeerInfo) {}

    override fun send(message: TransportMessage, to: List<PeerInfo>) {
        sentMessages.add(message)
    }

    override fun sendAudioData(data: ByteArray, to: List<PeerInfo>) {
        sentAudioData.add(data)
    }

    override fun sendFile(file: File, name: String, to: PeerInfo) {}

    // --- Test helpers to inject incoming messages ---

    fun injectTextMessage(payload: TextPayload, from: PeerInfo = PeerInfo(displayName = "RemotePeer")) {
        _textMessages.tryEmit(payload to from)
    }

    fun injectControlMessage(control: WalkieTalkieControlType, from: PeerInfo = PeerInfo(displayName = "RemotePeer")) {
        _controlMessages.tryEmit(control to from)
    }

    fun injectChannelAnnounce(announce: ChannelAnnouncePayload, from: PeerInfo = PeerInfo(displayName = "RemotePeer")) {
        _channelAnnounces.tryEmit(announce to from)
    }

    fun injectFileHeader(header: FileHeaderPayload, from: PeerInfo = PeerInfo(displayName = "RemotePeer")) {
        _fileHeaders.tryEmit(header to from)
    }

    fun injectFileChunk(chunk: FileChunkPayload, from: PeerInfo = PeerInfo(displayName = "RemotePeer")) {
        _fileChunks.tryEmit(chunk to from)
    }

    fun injectPeerEvent(event: PeerEvent, peer: PeerInfo) {
        _peerEvents.tryEmit(PeerEventData(event, peer))
    }

    fun simulateConnectedPeer(peer: PeerInfo) {
        _connectedPeers.value = _connectedPeers.value + peer
    }
}
