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
    /// Counts the pages that changed what was shown when the screen came back
    /// (Home's fresh feed over a saved or aged one, History on a visit),
    /// which start from the top: the reader's place belonged to the page
    /// replaced.
    private(set) var replacements = 0

    @ObservationIgnored private var generation = 0
    /// The account the page shown was loaded for.
    @ObservationIgnored private var shownFor: Int?
    /// Whether the page shown is Home's saved feed, standing in while YouTube
    /// is first asked, or for a feed it refused, which the next visit replaces.
    @ObservationIgnored private var showsSaved = false
    /// When the page shown was put on screen, so Home loads afresh once older
    /// than the page cache keeps pages; one from the cache may be older still.
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var loadingMore = false

    /// Shows a page the cache still holds at once, as ytm-native's `navigate`
    /// does, so a page returned to within five minutes has no spinner or rise.
    init(route: Route, app: AppModel) {
        self.route = route
        if app.accountGeneration > 0, let page = app.cachedPage(route) { show(page, for: app) }
    }

    var page: Page? {
        if case .loaded(let page) = phase { page } else { nil }
    }

    /// Loads the page when the screen shows, unless it already holds this
    /// account's. The account's History is fetched afresh each visit, as
    /// ytm-native does, keeping the songs shown meanwhile, and so is Home
    /// while its saved feed stands in, or once its feed has aged past the
    /// page cache's five minutes: the app stays alive for days, so a feed
    /// loaded once would otherwise never change. Any other page loads afresh
    /// once it has left the page cache (aged past five minutes, pushed out,
    /// or forgotten after a library change), as ytm-native's `navigate`
    /// checks the cache on every visit. `returning` is a return to the app
    /// with the page on screen, which ytm-native never refetches it for, so
    /// only Home's age counts then.
    func appear(in app: AppModel, returning: Bool) async {
        guard app.accountGeneration > 0 else { return }
        if shownFor == app.accountGeneration, route != .history, !showsSaved, !isStale(in: app, returning: returning) { return }
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
        // Home's fresh feed and History's latest plays start from the top when
        // they differ from what was shown; the same page again, or any other
        // page loaded afresh on a visit, keeps the reader's place, as
        // ytm-native's `restore_scroll`.
        func present(_ page: Page, saved: Bool = false) {
            if cached, let shown = self.page, route == .home || route == .history,
               shown.sections != page.sections || shown.header != page.header {
                replacements += 1
            }
            show(page, for: app, saved: saved)
        }
        if cached, let page = app.cachedPage(route) {
            present(page)
            return
        }
        // Signed in, Home asks for the feed once. Refused, the feed as it last
        // loaded shows at once, and the retries behind it wait for the next
        // visit, as ytm-native's `load_personal_home`. With nothing saved, the
        // retries and then the charts follow below. With nothing shown yet, as
        // at launch, the saved feed stands in for the spinner during that one
        // request, and what it brings replaces it a moment later, as it does
        // a feed aged past the page cache's time.
        if route == .home, app.isSignedIn {
            if page == nil, let saved = await app.savedHome() {
                guard isCurrent(generation, account, in: app) else { return }
                present(saved, saved: true)
            }
            do {
                let page = try await app.fetchHomeFirstTry()
                guard isCurrent(generation, account, in: app) else { return }
                present(page)
                return
            } catch {
                guard isCurrent(generation, account, in: app), !Task.isCancelled else { return }
                if !showsSaved, let saved = await app.savedHome() {
                    guard isCurrent(generation, account, in: app) else { return }
                    present(saved, saved: true)
                }
                if showsSaved {
                    app.refreshHome()
                    return
                }
            }
        }
        do {
            let page = try await app.fetchPage(route)
            guard isCurrent(generation, account, in: app) else { return }
            present(page)
        } catch {
            // A change of account cancels the last account's requests, whose
            // failure is no news: the page loads afresh for the new one.
            guard isCurrent(generation, account, in: app), !Task.isCancelled else { return }
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

    /// Home's feed is older than the page cache keeps pages (one shown from the
    /// cache may be older still); any other page is no longer in the cache, as
    /// ytm-native's `navigate` refetches a page aged out or forgotten, though
    /// not on a return to the app.
    private func isStale(in app: AppModel, returning: Bool) -> Bool {
        guard route == .home else { return !returning && app.cachedPage(route) == nil }
        guard let shownAt else { return false }
        return shownAt.duration(to: .now) >= AppModel.pageCacheFor
    }

    private func show(_ page: Page, for app: AppModel, saved: Bool = false) {
        phase = .loaded(page)
        shownFor = app.accountGeneration
        shownAt = .now
        showsSaved = saved
        step += 1
    }
}
