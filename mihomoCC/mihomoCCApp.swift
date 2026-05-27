import SwiftUI

@main
struct mihomoCCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Pure menu bar app — no regular windows
        Settings { EmptyView() }
    }
}
