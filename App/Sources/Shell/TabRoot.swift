import SwiftUI
import YTMCore

/// One tab: its own stack of pages, with the account button that opens
/// Settings, as ytm-native's top bar has, the mini player above the tab bar
/// while there is a song, and the toast above that while no sheet covers it
/// (sheets show it too).
///
/// The mini player is the app's own rather than the tab bar's accessory,
/// whose height the system fixes too small to reach comfortably. Each tab
/// has its own, the source Now Playing grows out of while that tab is in
/// view, so the sources never share an ID.
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
                .navigationDestination(for: Route.self) { PageScreen(route: $0) }
        }
        .overlay(alignment: .bottom) { ToastView() }
        // Empty without a song, which leaves the pages their full height.
        .safeAreaInset(edge: .bottom) {
            MiniPlayer(tab: tab, transition: transition)
        }
    }
}
