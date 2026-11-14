import Observation
import YTMCore

/// One screen's page as it loads, as ytm-native's `navigate`, `page_loaded`
/// and `complete_page`. Each load is numbered, so a late result of one the
/// screen has moved past never shows.
@Observable
final class PageModel {
    enum Phase {
        case loading
        case loaded(Page)
        case failed(String)
    }

    let route: Route
    private(set) var phase = Phase.loading
    /// Counts the pages shown, so the screen asks for the next step of
    /// `Page.more` once the last has arrived.
    private(set) var step = 0

    @ObservationIgnored private var generation = 0
    /// The account the page shown was loaded for.
    @ObservationIgnored private var shownFor: Int?
    /// Whether the page shown is Home's saved feed, standing in for one
    /// YouTube refused, which the next visit replaces.
    @ObservationIgnored private var showsSaved = false
    @ObservationIgnored private var loadingMore = false

    init(route: Route) {
        self.route = route
    }

    var page: Page? {
        if case .loaded(let page) = phase { page } else { nil }
    }

    /// Loads the page when the screen shows, unless it already holds this
    /// account's. The account's History is fetched afresh each visit, as
    /// ytm-native does, keeping the songs shown meanwhile, and so is Home
    /// while its saved feed stands in.
    func appear(in app: AppModel) async {
        guard app.accountGeneration > 0 else { return }
        if shownFor == app.accountGeneration, route != .history, !showsSaved { return }
        if shownFor != app.accountGeneration { phase = .loading }
        await load(in: app, cached: true)
    }

    /// Pull to refresh: the page loads afresh while the old one stays.
    func refresh(in app: AppModel) async {
        app.forget(route)
        await load(in: app, cached: false)
    }

    func retry(in app: AppModel) async {
        phase = .loading
        await load(in: app, cached: false)
    }

    /// The next step of what the page still has to fetch, asked for while
    /// the page is on screen.
    func loadMore(in app: AppModel) async {
        guard let page, page.more != nil, !loadingMore else { return }
        let generation = generation
        let account = app.accountGeneration
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        guard let more = try? await app.fetchMore(of: page, for: route), isCurrent(generation, account, in: app) else { return }
        show(more, for: app)
    }

    private func load(in app: AppModel, cached: Bool) async {
        generation += 1
        let generation = generation
        let account = app.accountGeneration
        loadingMore = false
        if cached, let page = app.cachedPage(route) {
            show(page, for: app)
            return
        }
        // Signed in, Home asks for the feed once. Refused, the feed as it last
        // loaded shows at once, and the retries behind it wait for the next
        // visit, so the page never changes under the reader, as ytm-native's
        // `load_personal_home`. With nothing saved, the retries and then the
        // charts follow below.
        if route == .home, app.isSignedIn {
            do {
                let page = try await app.fetchHomeFirstTry()
                guard isCurrent(generation, account, in: app) else { return }
                show(page, for: app)
                return
            } catch {
                guard isCurrent(generation, account, in: app), !Task.isCancelled else { return }
                if let saved = await app.savedHome() {
                    guard isCurrent(generation, account, in: app) else { return }
                    show(saved, for: app, saved: true)
                    app.refreshHome()
                    return
                }
            }
        }
        do {
            let page = try await app.fetchPage(route)
            guard isCurrent(generation, account, in: app) else { return }
            show(page, for: app)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            if self.page == nil {
                phase = .failed(sentence(for: error))
            } else {
                // What was shown stays.
                app.showToast(sentence(for: error))
            }
        }
    }

    /// Whether a result asked for by load `generation`, for `account`, is
    /// still wanted: neither the screen nor the account has moved on.
    private func isCurrent(_ generation: Int, _ account: Int, in app: AppModel) -> Bool {
        generation == self.generation && account == app.accountGeneration
    }

    private func show(_ page: Page, for app: AppModel, saved: Bool = false) {
        phase = .loaded(page)
        shownFor = app.accountGeneration
        showsSaved = saved
        step += 1
    }
}
