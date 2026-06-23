import SwiftUI

@main
struct CycleHUDWatchApp: App {
    @StateObject private var session = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(session)
        }
    }
}
