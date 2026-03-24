import Foundation
import SwiftUI
import SwiftData

@Observable
final class AppCoordinator {
    var selectedTab: AppTab = .nearby
    var chatPath = NavigationPath()
    var walkieTalkiePath = NavigationPath()

    let transport: MultipeerTransport
    let chatService: ChatService
    let fileShareService: FileShareService
    let walkieTalkieService: WalkieTalkieService
    let audioEngine: AudioEngine

    init(displayName: String) {
        let transport = MultipeerTransport(displayName: displayName)
        let audioEngine = AudioEngine()

        self.transport = transport
        self.audioEngine = audioEngine
        self.chatService = ChatService(transport: transport)
        self.fileShareService = FileShareService(transport: transport)
        self.walkieTalkieService = WalkieTalkieService(transport: transport, audioEngine: audioEngine)
    }

    func start(modelContext: ModelContext) {
        chatService.configure(modelContext: modelContext)
        transport.start()
        walkieTalkieService.startListening()
    }

    func stop() {
        transport.stop()
    }

    // MARK: - Navigation

    func navigateToChat(with peer: PeerInfo) {
        selectedTab = .chats
        chatPath.append(ChatRoute.room(peer))
    }

    func navigateToWalkieTalkie(channel: Channel) {
        selectedTab = .walkieTalkie
        walkieTalkiePath.append(WalkieTalkieRoute.channel(channel.id))
    }
}
