import SwiftUI

@main
struct PiChatApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(store)
        }
    }
}
