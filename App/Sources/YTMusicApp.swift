import SwiftUI

/// The app's entry: one `AppModel` for the whole app, and the session saved
/// as the app leaves the screen, which on a phone may be the last chance.
@main
struct YTMusicApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// Starts the app here rather than once the window shows, so Home's feed,
    /// which YouTube takes most of a second to build, is asked for while
    /// the window is made, as ytm-native's `main` does.
    init() {
        let app = AppModel()
        _app = State(initialValue: app)
        Task { await app.start() }
    }

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
