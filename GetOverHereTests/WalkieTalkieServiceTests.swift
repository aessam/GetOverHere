import Testing
@testable import GetOverHere

@MainActor
struct WalkieTalkieServiceTests {
    private func makeService() -> (WalkieTalkieService, MockTransport) {
        let transport = MockTransport(displayName: "Tester")
        let audioEngine = AudioEngine()
        let service = WalkieTalkieService(transport: transport, audioEngine: audioEngine)
        service.startListening()
        return (service, transport)
    }

    @Test func createChannelAddsToList() {
        let (service, _) = makeService()
        let channel = service.createChannel(name: "Tour Group")

        #expect(service.channels.count == 1)
        #expect(service.channels.first?.name == "Tour Group")
        #expect(service.currentChannel?.id == channel.id)
    }

    @Test func createChannelNotifiesPeers() {
        let (service, transport) = makeService()
        _ = service.createChannel(name: "Test")

        #expect(transport.sentMessages.count == 1)
        if case .walkieTalkieControl(let control) = transport.sentMessages.first?.0 {
            if case .joinChannel(_, _, let peerID, _) = control {
                #expect(peerID == transport.localPeer.id)
            } else {
                Issue.record("Expected joinChannel control")
            }
        } else {
            Issue.record("Expected walkieTalkieControl message")
        }
    }

    @Test func pushToTalkChangesState() {
        let (service, _) = makeService()
        _ = service.createChannel(name: "Test")

        #expect(service.floorState == .idle)
        service.pushToTalk()
        #expect(service.floorState == .broadcasting)
    }

    @Test func releaseFloorResetsState() {
        let (service, _) = makeService()
        _ = service.createChannel(name: "Test")

        service.pushToTalk()
        #expect(service.floorState == .broadcasting)

        service.releaseFloor()
        #expect(service.floorState == .idle)
    }

    @Test func pushToTalkSendsFloorRequest() {
        let (service, transport) = makeService()
        let channel = service.createChannel(name: "Test")
        transport.sentMessages.removeAll() // Clear the joinChannel message

        service.pushToTalk()

        #expect(transport.sentMessages.count == 1)
        if case .walkieTalkieControl(let control) = transport.sentMessages.first?.0 {
            if case .requestFloor(let channelID, _, _) = control {
                #expect(channelID == channel.id.uuidString)
            } else {
                Issue.record("Expected requestFloor")
            }
        }
    }

    @Test func leaveChannelClearsState() {
        let (service, _) = makeService()
        _ = service.createChannel(name: "Test")
        #expect(service.currentChannel != nil)

        service.leaveChannel()
        #expect(service.currentChannel == nil)
        #expect(service.floorState == .idle)
    }

    @Test func incomingFloorRequestSetsListening() async throws {
        let (service, transport) = makeService()
        let channel = service.createChannel(name: "Test")
        let peer = PeerInfo(id: "speaker", displayName: "Speaker")

        transport.simulateIncomingControl(
            .requestFloor(channelID: channel.id.uuidString, peerID: peer.id, peerName: peer.displayName),
            from: peer
        )

        try await Task.sleep(for: .milliseconds(100))
        #expect(service.floorState == .listening(speakerName: "Speaker"))
    }

    @Test func incomingReleaseFloorResetsToIdle() async throws {
        let (service, transport) = makeService()
        let channel = service.createChannel(name: "Test")
        let peer = PeerInfo(id: "speaker", displayName: "Speaker")

        // First take floor
        transport.simulateIncomingControl(
            .requestFloor(channelID: channel.id.uuidString, peerID: peer.id, peerName: peer.displayName),
            from: peer
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.floorState == .listening(speakerName: "Speaker"))

        // Then release
        transport.simulateIncomingControl(
            .releaseFloor(channelID: channel.id.uuidString, peerID: peer.id),
            from: peer
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.floorState == .idle)
    }
}
