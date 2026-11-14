import SwiftUI

/// The app's entry: one `AppModel` for the whole app, and the session saved
/// as the app leaves the screen, which on a phone may be the last chance.
@main
struct YTMusicApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { app.player.persistSession() }
        }
    }
}
