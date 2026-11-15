import Foundation
import YTMCore

/// A loaded page kept for returning to it, as ytm-native's `page_cache`.
struct CachedPage {
    var page: Page
    let at: ContinuousClock.Instant
}

/// The page cache, as ytm-native's `navigation.rs`: pages are reused for five
/// minutes, twelve at most, and what a past account asked for never lands.
extension AppModel {
    static let pageCacheSize = 12
    static let pageCacheFor: Duration = .seconds(5 * 60)

    /// `route`'s page as loaded within the last five minutes.
    func cachedPage(_ route: Route) -> Page? {
        guard let cached = pageCache[route], cached.at.duration(to: .now) < Self.pageCacheFor else { return nil }
        return cached.page
    }

    /// `route`'s page fresh from YouTube, kept for going back. The history
    /// isn't kept, so a song just played shows next time. The request is not
    /// the screen's, so leaving it doesn't cancel it: the page still lands in
    /// the cache, as ytm-native's, and a second visit meanwhile shares it.
    func fetchPage(_ route: Route) async throws -> Page {
        if let load = pageLoads[route] { return try await load.value }
        let generation = accountGeneration
        let load = Task<Page, any Error> { [api] in
            defer { if generation == self.accountGeneration { self.pageLoads[route] = nil } }
            let page = try await api.page(route)
            if generation == self.accountGeneration, route != .history {
                self.cache(page, for: route)
            }
            return page
        }
        pageLoads[route] = load
        return try await load.value
    }

    /// The next step of what `page` has still to fetch, kept in the cache
    /// with the time the page first loaded, as ytm-native's `complete_page`,
    /// and whether it arrived whole. A page cut short by a failed step is
    /// dropped from the cache instead, so the next visit asks again, as
    /// ytm-native's `complete_home`. Leaving the screen doesn't cancel it,
    /// so Home is still saved whole; a step of a page refreshed meanwhile
    /// never overwrites the fresh one.
    func fetchMore(of page: Page, for route: Route) async throws -> (page: Page, whole: Bool) {
        let generation = accountGeneration
        let since = pageCache[route]?.at
        let step = try await Task { [api] in try await api.loadStep(page) }.value
        if generation == accountGeneration, pageCache[route]?.at == since {
            if step.whole { pageCache[route]?.page = step.page } else { pageCache[route] = nil }
        }
        return step
    }

    /// Drops `route`'s page, so it loads afresh.
    func forget(_ route: Route) {
        pageCache[route] = nil
    }

    /// After the player changed the account's library (a song rated, the
    /// queue saved as a playlist): the pages that show it load afresh.
    func libraryChanged() {
        for route in [Route.likedSongs, .library, .libraryPlaylists] { forget(route) }
    }

    /// What stands in for the signed-in Home while YouTube keeps refusing
    /// the feed (`YTMusic.homeStandIn`), read off the main actor; nil signed
    /// out, which has the charts as its Home.
    func homeStandIn() async -> Page? {
        guard isSignedIn else { return nil }
        return await api.homeStandIn()
    }

    private func cache(_ page: Page, for route: Route) {
        let now = ContinuousClock.now
        pageCache = pageCache.filter { $0.value.at.duration(to: now) < Self.pageCacheFor }
        if pageCache.count >= Self.pageCacheSize, let oldest = pageCache.min(by: { $0.value.at < $1.value.at })?.key {
            pageCache[oldest] = nil
        }
        pageCache[route] = CachedPage(page: page, at: now)
    }
}
