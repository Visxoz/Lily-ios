import SwiftUI
import YTMCore

/// Any page reached by a route, as ytm-native's `PageView`: Home, Explore,
/// genres, albums, playlists, artists, search results and the library all
/// load through the page cache and draw the same way.
struct PageScreen: View {
    let route: Route

    @State private var model: PageModel
    @Environment(AppModel.self) private var app

    init(route: Route) {
        self.route = route
        _model = State(initialValue: PageModel(route: route))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                PageStatus(phase: .loading, tint: Theme.routeTint(route))
            case .failed(let message):
                PageStatus(phase: .failed(message: message, action: "Try again") {
                    Task { await model.retry(in: app) }
                }, tint: Theme.routeTint(route))
            case .loaded(let page):
                // Rises into place as it fades in, as ytm-native's page does.
                PageContent(page: page, route: route, model: model)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.page != nil)
        // A new account loads the page afresh.
        .task(id: app.accountGeneration) { await model.appear(in: app) }
        // Completes the page while it is on screen, as ytm-native's
        // `complete_page`, so Home is saved whole.
        .task(id: model.step) { await model.loadMore(in: app) }
    }
}
