import SwiftUI

@main
struct PiChatApp: App {
    @State private var store = ChatStore()

    init() {
        BundledFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(store)
                .tint(Theme.accent)
        }
    }
}
