import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator
        TabView(selection: $coord.selectedTab) {
            Tab(AppTab.nearby.title, systemImage: AppTab.nearby.icon, value: .nearby) {
                NearbyView()
            }
            Tab(AppTab.chats.title, systemImage: AppTab.chats.icon, value: .chats) {
                ChatListView()
            }
            Tab(AppTab.files.title, systemImage: AppTab.files.icon, value: .files) {
                FileShareView()
            }
            Tab(AppTab.walkieTalkie.title, systemImage: AppTab.walkieTalkie.icon, value: .walkieTalkie) {
                WalkieTalkieView()
            }
        }
    }
}
