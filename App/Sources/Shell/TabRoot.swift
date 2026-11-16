import SwiftUI
import YTMCore

/// The mini player is the app's own since the tab bar accessory is too short to
/// reach comfortably; each tab has one, so the zoom sources never share an ID.
struct TabRoot<Content: View>: View {
    let tab: AppTab
    let transition: Namespace.ID
    let content: Content

    @Environment(AppModel.self) private var app

    init(tab: AppTab, transition: Namespace.ID, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.transition = transition
        self.content = content()
    }

    var body: some View {
        @Bindable var navigation = app.navigation(for: tab)
        NavigationStack(path: $navigation.routes) {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountButton() }
                }
                .navigationDestination(for: Route.self) { PageScreen(route: $0, app: app) }
        }
        .overlay(alignment: .bottom) { ToastView() }
        // Empty without a song, which leaves the pages their full height.
        .safeAreaInset(edge: .bottom) {
            MiniPlayer(tab: tab, transition: transition)
        }
    }
}
