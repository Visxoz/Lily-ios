import SwiftUI
import YTMCore

/// Builds its model in its own body, not the parent's, so what building it reads (the account, and
/// the history for Home) never re-runs the tab tree or Search.
struct PageScreen: View {
    let route: Route

    @Environment(AppModel.self) private var app

    var body: some View {
        PageBody(route: route, app: app)
    }
}

private struct PageBody: View {
    let route: Route

    @State private var model: PageModel
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app went to the background with the page on screen, so the next visit is a return to the app, not the page.
    @State private var backgrounded = false

    /// A new account or a return from the background, as Home may have aged; Control Centre and the like leave the app
    /// in the foreground.
    private struct Visit: Hashable {
        let account: Int
        let foreground: Bool
    }

    init(route: Route, app: AppModel) {
        self.route = route
        _model = State(initialValue: PageModel(route: route, app: app))
    }

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                PageStatus(phase: .loading(route), tint: Theme.routeTint(route))
                    // Gone before the page is clear enough for the two to show through each other.
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.linear(duration: 0.18))))
            case .failed(let message):
                PageStatus(phase: .failed(message: message) {
                    Task { await model.retry(in: app) }
                }, tint: Theme.routeTint(route))
            case .loaded(let page):
                PageContent(page: page, route: route, model: model)
                    // Rising, it reads as arriving rather than switched on.
                    .transition(.asymmetric(
                        insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 16)))
                            .animation(.easeOut(duration: PageContent.arrival)),
                        removal: .opacity.animation(.easeOut(duration: 0.16))
                    ))
            }
        }
        // Still behind the rising page, so nothing shows through the gap it leaves.
        .background { theme.panel.ignoresSafeArea() }
        .animation(.easeOut(duration: 0.3), value: model.page != nil)
        .task(id: Visit(account: app.accountGeneration, foreground: scenePhase != .background)) {
            guard scenePhase != .background else {
                backgrounded = true
                return
            }
            let returning = backgrounded
            backgrounded = false
            await model.appear(in: app, returning: returning)
        }
        // Completes the page while it is on screen, so Home is saved whole.
        .task(id: model.step) { await model.loadMore(in: app) }
        // Read only where used: pins lead Library, and a saved queue joins its playlists.
        .onChange(of: route == .library ? app.pinned : []) { model.rearrange(in: app) }
        .onChange(of: route.listsPlaylists ? app.playlistsAdded : 0) { model.adoptCached(in: app) }
    }
}
