import SwiftUI

/// The History tab, as ytm-native's: signed in with plays sent to YouTube,
/// the account's own history, fetched each visit so plays elsewhere show;
/// otherwise the songs played here, without any fetching.
struct HistoryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isSignedIn && app.settings.value.youtubeHistory {
            PageScreen(route: .history)
        } else {
            LocalHistoryScreen()
        }
    }
}

/// The songs played on this device, as ytm-native's `history_page`.
private struct LocalHistoryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let page = app.history.page {
            PageContent(page: page, route: .history)
        } else {
            PageStatus(phase: .empty("Songs you play will show up here."), tint: Theme.routeTint(.history))
        }
    }
}
