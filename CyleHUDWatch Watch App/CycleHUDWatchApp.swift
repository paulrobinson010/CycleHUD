import SwiftUI

@main
struct CycleHUDWatchApp: App {
    @StateObject private var session = WatchSessionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(session)
        }
        .onChange(of: scenePhase) { _, phase in
            // Reopened mid-ride (or after watchOS killed the app): re-apply
            // the persisted mirror so the workout session restarts at once.
            if phase == .active { session.refreshFromContext() }
        }
    }
}
