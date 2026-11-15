import SwiftUI
import YTMCore

/// Any page reached by a route, as ytm-native's `PageView`: Home, Explore,
/// genres, albums, playlists, artists, search results and the library all
/// load through the page cache and draw the same way.
struct PageScreen: View {
    let route: Route

    @State private var model: PageModel
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// The app went to the background with the page on screen, so the next
    /// visit is a return to the app rather than to the page.
    @State private var backgrounded = false

    /// What the page loads afresh for: a new account, or the app coming back
    /// from the background, as Home may have aged meanwhile. Control Centre
    /// and the like leave the app in the foreground, so don't count.
    private struct Visit: Hashable {
        let account: Int
        let foreground: Bool
    }

    init(route: Route, app: AppModel) {
        self.route = route
        _model = State(initialValue: PageModel(route: route, app: app))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                PageStatus(phase: .loading, tint: Theme.routeTint(route))
            case .failed(let message):
                PageStatus(phase: .failed(message: message) {
                    Task { await model.retry(in: app) }
                }, tint: Theme.routeTint(route))
            case .loaded(let page):
                // Rises into place as it fades in, as ytm-native's page does.
                PageContent(page: page, route: route, model: model)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.page != nil)
        // A new account loads the page afresh, and so may a return to the app.
        .task(id: Visit(account: app.accountGeneration, foreground: scenePhase != .background)) {
            guard scenePhase != .background else {
                backgrounded = true
                return
            }
            let returning = backgrounded
            backgrounded = false
            await model.appear(in: app, returning: returning)
        }
        // Completes the page while it is on screen, as ytm-native's
        // `complete_page`, so Home is saved whole.
        .task(id: model.step) { await model.loadMore(in: app) }
    }
}
