package com.aessam.comeoverhere

import com.aessam.comeoverhere.core.*
import com.aessam.comeoverhere.service.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChannelServiceTest {

    private lateinit var transport: MockTransport
    private lateinit var audioEngine: AudioEngine
    private lateinit var service: ChannelService
    private lateinit var scope: TestScope

    @Before
    fun setup() {
        scope = TestScope(UnconfinedTestDispatcher())
        transport = MockTransport(displayName = "TestDevice")
        audioEngine = AudioEngine()
        service = ChannelService(transport, audioEngine, scope)
        service.start()
    }

    @After
    fun teardown() {
        service.stop()
        scope.cancel()
    }

    // --- Channel lifecycle ---

    @Test
    fun `townsquare exists on start`() {
        val channels = service.channels.value
        assertEquals(1, channels.size)
        assertEquals(Channel.TOWNSQUARE.id, channels[0].id)
        assertEquals("Townsquare", channels[0].name)
    }

    @Test
    fun `active channel is townsquare on start`() {
        assertEquals(Channel.TOWNSQUARE.id, service.activeChannelID.value)
    }

    @Test
    fun `create channel adds to list and switches to it`() {
        service.createChannel("Photos")

        val channels = service.channels.value
        assertEquals(2, channels.size)
        assertEquals("Photos", channels[1].name)
        assertEquals(channels[1].id, service.activeChannelID.value)
    }

    @Test
    fun `create channel broadcasts channelAnnounce`() {
        service.createChannel("Road Trip")

        val sent = transport.sentMessages.filterIsInstance<TransportMessage.ChannelAnnounce>()
        assertEquals(1, sent.size)
        assertEquals("Road Trip", sent[0].announce.channelName)
        assertEquals(transport.localPeer.id, sent[0].announce.createdBy)
    }

    @Test
    fun `select channel changes active channel`() {
        service.createChannel("Other")
        val otherID = service.channels.value.find { it.name == "Other" }!!.id

        service.selectChannel(Channel.TOWNSQUARE.id)
        assertEquals(Channel.TOWNSQUARE.id, service.activeChannelID.value)

        service.selectChannel(otherID)
        assertEquals(otherID, service.activeChannelID.value)
    }

    // --- Channel announce (discovery) ---

    @Test
    fun `receiving channelAnnounce adds new channel`() = scope.runTest {
        val announce = ChannelAnnouncePayload(
            channelID = "new-channel-id",
            channelName = "Discovered",
            createdAt = 100.0,
            createdBy = "remote-peer"
        )
        transport.injectChannelAnnounce(announce)
        advanceUntilIdle()

        val channels = service.channels.value
        assertEquals(2, channels.size)
        assertEquals("Discovered", channels[1].name)
    }

    @Test
    fun `duplicate channelAnnounce is idempotent`() = scope.runTest {
        val announce = ChannelAnnouncePayload(
            channelID = "dup-id",
            channelName = "DupChannel",
            createdAt = 100.0,
            createdBy = "remote-peer"
        )
        transport.injectChannelAnnounce(announce)
        advanceUntilIdle()
        transport.injectChannelAnnounce(announce)
        advanceUntilIdle()

        val matches = service.channels.value.filter { it.id == "dup-id" }
        assertEquals(1, matches.size)
    }

    // --- Text messages ---

    @Test
    fun `send text message adds to active messages`() {
        service.sendTextMessage("Hello world")

        val messages = service.activeMessages.value
        assertEquals(1, messages.size)
        assertEquals("Hello world", messages[0].content)
        assertTrue(messages[0].isFromMe)
        assertEquals(Channel.TOWNSQUARE.id, messages[0].channelID)
    }

    @Test
    fun `send text broadcasts via transport`() {
        service.sendTextMessage("Test")

        val sent = transport.sentMessages.filterIsInstance<TransportMessage.Text>()
        assertEquals(1, sent.size)
        assertEquals("Test", sent[0].payload.content)
        assertEquals(Channel.TOWNSQUARE.id, sent[0].payload.channelID)
        assertEquals(transport.localPeer.id, sent[0].payload.senderID)
    }

    @Test
    fun `receive text message from remote peer`() = scope.runTest {
        val payload = TextPayload(
            channelID = Channel.TOWNSQUARE.id,
            senderID = "remote-id",
            senderName = "Alice",
            content = "Hi from Alice"
        )
        transport.injectTextMessage(payload)
        advanceUntilIdle()

        val messages = service.activeMessages.value
        assertEquals(1, messages.size)
        assertEquals("Hi from Alice", messages[0].content)
        assertFalse(messages[0].isFromMe)
        assertEquals("Alice", messages[0].senderName)
    }

    @Test
    fun `own messages from transport are deduplicated`() = scope.runTest {
        val payload = TextPayload(
            channelID = Channel.TOWNSQUARE.id,
            senderID = transport.localPeer.id,  // Same as local
            senderName = "TestDevice",
            content = "Echo"
        )
        transport.injectTextMessage(payload)
        advanceUntilIdle()

        // Should be ignored (dedup by senderID)
        assertEquals(0, service.activeMessages.value.size)
    }

    @Test
    fun `messages route to correct channel`() = scope.runTest {
        service.createChannel("Other")
        val otherID = service.channels.value.find { it.name == "Other" }!!.id

        // Send in Other channel (currently active)
        service.sendTextMessage("In Other")

        // Receive in Townsquare
        val payload = TextPayload(
            channelID = Channel.TOWNSQUARE.id,
            senderID = "remote-id",
            senderName = "Bob",
            content = "In Townsquare"
        )
        transport.injectTextMessage(payload)
        advanceUntilIdle()

        // Active channel is Other — should only see "In Other"
        assertEquals(1, service.activeMessages.value.size)
        assertEquals("In Other", service.activeMessages.value[0].content)

        // Switch to Townsquare
        service.selectChannel(Channel.TOWNSQUARE.id)
        assertEquals(1, service.activeMessages.value.size)
        assertEquals("In Townsquare", service.activeMessages.value[0].content)
    }

    // --- Floor control ---

    @Test
    fun `floor starts as IDLE`() {
        assertEquals(FloorState.IDLE, service.activeFloorInfo.value.state)
    }

    @Test
    fun `togglePTT starts broadcasting`() {
        service.togglePTT()

        assertEquals(FloorState.BROADCASTING, service.activeFloorInfo.value.state)
        // Should have sent RequestFloor
        val sent = transport.sentMessages.filterIsInstance<TransportMessage.WalkieTalkieControl>()
        assertTrue(sent.any { it.control is WalkieTalkieControlType.RequestFloor })
    }

    @Test
    fun `togglePTT twice returns to IDLE`() {
        service.togglePTT()
        assertEquals(FloorState.BROADCASTING, service.activeFloorInfo.value.state)

        service.togglePTT()
        assertEquals(FloorState.IDLE, service.activeFloorInfo.value.state)

        // Should have sent ReleaseFloor
        val sent = transport.sentMessages.filterIsInstance<TransportMessage.WalkieTalkieControl>()
        assertTrue(sent.any { it.control is WalkieTalkieControlType.ReleaseFloor })
    }

    @Test
    fun `receive RequestFloor sets LISTENING`() = scope.runTest {
        val control = WalkieTalkieControlType.RequestFloor(
            channelID = Channel.TOWNSQUARE.id,
            peerID = "remote-id",
            peerName = "Alice"
        )
        transport.injectControlMessage(control)
        advanceUntilIdle()

        assertEquals(FloorState.LISTENING, service.activeFloorInfo.value.state)
        assertEquals("Alice", service.activeFloorInfo.value.speakerName)
    }

    @Test
    fun `receive ReleaseFloor returns to IDLE from LISTENING`() = scope.runTest {
        // First set to listening
        transport.injectControlMessage(
            WalkieTalkieControlType.RequestFloor(Channel.TOWNSQUARE.id, "remote-id", "Alice")
        )
        advanceUntilIdle()
        assertEquals(FloorState.LISTENING, service.activeFloorInfo.value.state)

        // Then release
        transport.injectControlMessage(
            WalkieTalkieControlType.ReleaseFloor(Channel.TOWNSQUARE.id, "remote-id")
        )
        advanceUntilIdle()
        assertEquals(FloorState.IDLE, service.activeFloorInfo.value.state)
        assertNull(service.activeFloorInfo.value.speakerName)
    }

    @Test
    fun `floor control from different channel is ignored`() = scope.runTest {
        val control = WalkieTalkieControlType.RequestFloor(
            channelID = "some-other-channel",
            peerID = "remote-id",
            peerName = "Alice"
        )
        transport.injectControlMessage(control)
        advanceUntilIdle()

        // Active channel is Townsquare, so this should update the other channel's state
        // but activeFloorInfo should still be IDLE
        assertEquals(FloorState.IDLE, service.activeFloorInfo.value.state)
    }

    @Test
    fun `switching channels releases floor if broadcasting`() {
        service.createChannel("Other")
        service.selectChannel(Channel.TOWNSQUARE.id)
        service.togglePTT()
        assertEquals(FloorState.BROADCASTING, service.activeFloorInfo.value.state)

        val otherID = service.channels.value.find { it.name == "Other" }!!.id
        service.selectChannel(otherID)

        // Should have released floor and now be IDLE on Other channel
        assertEquals(FloorState.IDLE, service.activeFloorInfo.value.state)
        val sent = transport.sentMessages.filterIsInstance<TransportMessage.WalkieTalkieControl>()
        assertTrue(sent.any { it.control is WalkieTalkieControlType.ReleaseFloor })
    }

    // --- Channel sync ---

    @Test
    fun `peer connect triggers channel sync`() = scope.runTest {
        service.createChannel("Photos")
        transport.sentMessages.clear()

        val newPeer = PeerInfo(displayName = "NewDevice")
        transport.injectPeerEvent(PeerEvent.CONNECTED, newPeer)
        advanceUntilIdle()

        // Should have broadcast channelAnnounce for both Townsquare and Photos
        val announces = transport.sentMessages.filterIsInstance<TransportMessage.ChannelAnnounce>()
        assertEquals(2, announces.size)
    }

    // --- Wire format ---

    @Test
    fun `text message wire format matches spec`() {
        service.sendTextMessage("Hello")

        val sent = transport.sentMessages[0] as TransportMessage.Text
        val json = sent.toJson()

        // Parse it back
        val parsed = parseTransportMessage(json)
        assertNotNull(parsed)
        assertTrue(parsed is TransportMessage.Text)

        val roundTripped = (parsed as TransportMessage.Text).payload
        assertEquals("Hello", roundTripped.content)
        assertEquals(Channel.TOWNSQUARE.id, roundTripped.channelID)
        assertEquals(transport.localPeer.id, roundTripped.senderID)
    }

    @Test
    fun `channelAnnounce wire format roundtrip`() {
        service.createChannel("TestChannel")

        val sent = transport.sentMessages.filterIsInstance<TransportMessage.ChannelAnnounce>()[0]
        val json = sent.toJson()
        val parsed = parseTransportMessage(json)

        assertNotNull(parsed)
        assertTrue(parsed is TransportMessage.ChannelAnnounce)
        val roundTripped = (parsed as TransportMessage.ChannelAnnounce).announce
        assertEquals("TestChannel", roundTripped.channelName)
    }

    @Test
    fun `swift reference date conversion roundtrip`() {
        val now = System.currentTimeMillis()
        val swiftRef = unixMillisToSwiftRef(now)
        val backToUnix = swiftRefToUnixMillis(swiftRef)
        // Should match within 1ms (double precision)
        assertTrue(kotlin.math.abs(now - backToUnix) <= 1)
    }

    @Test
    fun `known swift reference date`() {
        // 2026-03-23 00:00:00 UTC = 796348800.0 in Swift reference
        // Unix: 796348800.0 + 978307200 = 1774656000
        val swiftRef = 796348800.0
        val unix = swiftRefToUnixMillis(swiftRef)
        assertEquals(1774656000000L, unix)
    }

    // --- File transfer ---

    @Test
    fun `receive fileHeader creates placeholder message`() = scope.runTest {
        val header = FileHeaderPayload(
            transferID = "transfer-1",
            channelID = Channel.TOWNSQUARE.id,
            senderID = "remote-id",
            senderName = "Alice",
            fileName = "photo.jpg",
            fileSize = 1024,
            mimeType = "image/jpeg"
        )
        transport.injectFileHeader(header)
        advanceUntilIdle()

        val messages = service.activeMessages.value
        assertEquals(1, messages.size)
        assertEquals("photo.jpg", messages[0].fileName)
        assertEquals(1024, messages[0].fileSize)
        assertEquals("image/jpeg", messages[0].mimeType)
        assertFalse(messages[0].isFromMe)
    }

    @Test
    fun `message dedup prevents duplicates`() = scope.runTest {
        val payload = TextPayload(
            id = "same-id",
            channelID = Channel.TOWNSQUARE.id,
            senderID = "remote-id",
            senderName = "Alice",
            content = "Dup test"
        )
        transport.injectTextMessage(payload)
        advanceUntilIdle()
        transport.injectTextMessage(payload)
        advanceUntilIdle()

        assertEquals(1, service.activeMessages.value.size)
    }
}
