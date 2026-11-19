import Observation
import YTMCore

/// Each load is numbered, so a late result of one the screen has moved past
/// never shows.
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
    /// Counts pages that replaced what was shown on a return, which start from
    /// the top: the reader's place belonged to the page replaced.
    private(set) var replacements = 0

    @ObservationIgnored private var generation = 0
    /// The account the page shown was loaded for.
    @ObservationIgnored private var shownFor: Int?
    /// The page as YouTube sent it, before recent plays join Home's Speed
    /// dial, so further steps, the cache, the saved feed and change checks use
    /// YouTube's.
    @ObservationIgnored private var source: Page?

    /// Whether the page stands in for Home's feed until the next visit: the
    /// saved feed or the charts, or a feed cut short by a step that failed.
    @ObservationIgnored private var showsSaved = false
    /// So Home loads afresh once older than the page cache keeps pages; one
    /// from the cache may be older still.
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var loadingMore = false

    /// Shows a page the cache still holds at once, so a page returned to
    /// within five minutes has no skeleton or fade.
    init(route: Route, app: AppModel) {
        self.route = route
        if app.accountGeneration > 0, let page = app.cachedPage(route) { show(page, for: app) }
    }

    var page: Page? {
        if case .loaded(let page) = phase { page } else { nil }
    }

    /// The layouts of Home's shelves yet to come: neither sent (YouTube's may be dropped) nor shown.
    var shelvesToCome: [CardLayout?] {
        let arrived = Set(((source?.sections ?? []) + (page?.sections ?? [])).map(\.title))
        return YTMusic.homeShelves.filter { !arrived.contains($0.title) }.map(\.layout)
    }

    /// Skips the load if it already holds this account's page, except History
    /// each visit, Home while a stand-in shows, and any page once `isStale`.
    func appear(in app: AppModel, returning: Bool) async {
        guard app.accountGeneration > 0 else { return }
        if shownFor == app.accountGeneration {
            mixInRecentPlays(in: app)
            if route != .history, !showsSaved, !isStale(in: app, returning: returning) { return }
        } else {
            clear()
        }
        await load(in: app, cached: true)
    }

    /// The old page stays while the new one loads.
    func refresh(in app: AppModel) async {
        app.forget(route)
        await load(in: app, cached: false)
    }

    func retry(in app: AppModel) async {
        clear()
        await load(in: app, cached: false)
    }

    func loadMore(in app: AppModel) async {
        guard let source, source.more != nil, !loadingMore else { return }
        let generation = generation
        let account = app.accountGeneration
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        guard let step = try? await app.fetchMore(of: source, for: route), isCurrent(generation, account, in: app) else { return }
        show(step.page, for: app, saved: !step.whole)
    }

    private func load(in app: AppModel, cached: Bool) async {
        generation += 1
        let generation = generation
        let account = app.accountGeneration
        // No step of the page shown starts meanwhile, as it would land over
        // the page this load brings. Cleared before what this load shows asks
        // for its own next step.
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        // Only Home's and History's pages start from the top, and only when
        // they differ from what was shown; others keep the reader's place.
        func present(_ page: Page, saved: Bool = false) {
            if cached, let shown = source, route == .home || route == .history,
               shown.sections != page.sections || shown.header != page.header {
                replacements += 1
            }
            show(page, for: app, saved: saved)
        }
        if cached, let page = app.cachedPage(route) {
            present(page)
            return
        }
        do {
            let page = try await app.fetchPage(route)
            guard isCurrent(generation, account, in: app) else { return }
            present(page)
        } catch {
            // A change of account cancels the last account's requests, whose
            // failure is no news: the page loads afresh for the new one.
            guard isCurrent(generation, account, in: app) else { return }
            // This load dropped any step of the page shown in flight, so the
            // page carries on from where it was.
            guard !Task.isCancelled else {
                if self.page != nil { step += 1 }
                return
            }
            // The saved feed or the charts stand in only once every request
            // has failed, and the next visit asks again; a feed on screen
            // stays instead.
            if route == .home, self.page == nil, let standIn = await app.homeStandIn() {
                guard isCurrent(generation, account, in: app) else { return }
                present(standIn, saved: true)
            } else if self.page == nil {
                phase = .failed(sentence(for: error))
            } else {
                // What was shown stays and carries on from where it was.
                mixInRecentPlays(in: app)
                app.showToast(sentence(for: error))
                step += 1
            }
        }
    }

    private func isCurrent(_ generation: Int, _ account: Int, in app: AppModel) -> Bool {
        generation == self.generation && account == app.accountGeneration
    }

    /// Home ages out with the page cache, as the app stays alive for days; any
    /// other page is stale once out of the cache, unless `returning` with it
    /// on screen.
    private func isStale(in app: AppModel, returning: Bool) -> Bool {
        guard route == .home else { return !returning && app.cachedPage(route) == nil }
        guard let shownAt else { return false }
        return shownAt.duration(to: .now) >= AppModel.pageCacheFor
    }

    private func clear() {
        phase = .loading
        source = nil
        showsSaved = false
    }

    /// Mixes what played since into the kept page's Speed dial. Not a new
    /// feed, so the reader's place stays.
    private func mixInRecentPlays(in app: AppModel) {
        guard let source, let shown = page else { return }
        let latest = onScreen(source, in: app)
        if latest != shown { phase = .loaded(latest) }
    }

    /// Signed in, Home's Speed dial takes in this phone's recent plays, as
    /// YouTube's seldom has them.
    private func onScreen(_ page: Page, in app: AppModel) -> Page {
        guard route == .home, app.isSignedIn else { return page }
        return page.withRecentPlays(app.history.history.tracks)
    }

    private func show(_ page: Page, for app: AppModel, saved: Bool = false) {
        source = page
        phase = .loaded(onScreen(page, in: app))
        shownFor = app.accountGeneration
        shownAt = .now
        showsSaved = saved
        step += 1
    }
}
