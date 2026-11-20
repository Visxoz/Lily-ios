import Foundation
import YTMCore

struct CachedPage {
    var page: Page
    let at: ContinuousClock.Instant
}

extension AppModel {
    static let pageCacheSize = 12
    static let pageCacheFor: Duration = .seconds(5 * 60)

    func cachedPage(_ route: Route) -> Page? {
        guard let cached = pageCache[route], cached.at.duration(to: .now) < Self.pageCacheFor else { return nil }
        return cached.page
    }

    /// History isn't cached, so a song just played shows next time. Leaving the screen doesn't
    /// cancel the request: the page still lands in the cache, and a second visit shares it.
    /// If YouTube fails, a downloaded album or playlist falls back to the songs on the phone, uncached.
    func fetchPage(_ route: Route) async throws -> Page {
        if let load = pageLoads[route] { return try await load.value }
        let generation = accountGeneration
        let ahead = route == .home ? homeAhead.take() : nil
        let load = Task<Page, any Error> { [api] in
            defer { if generation == self.accountGeneration { self.pageLoads[route] = nil } }
            let page: Page
            do {
                if let ahead {
                    page = try await withTaskCancellationHandler { try await ahead.value } onCancel: { ahead.cancel() }
                } else {
                    page = try await api.page(route)
                }
            } catch {
                if !Task.isCancelled, let local = self.player.downloads.page(for: route) { return local }
                throw error
            }
            if generation == self.accountGeneration, route != .history {
                self.cache(page, for: route)
            }
            return page
        }
        pageLoads[route] = load
        return try await load.value
    }

    /// A page cut short by a failed step is dropped from the cache, so the next visit asks again.
    /// Leaving the screen doesn't cancel it; a step of a page refreshed meanwhile never lands.
    func fetchMore(of page: Page, for route: Route) async throws -> (page: Page, whole: Bool) {
        let generation = accountGeneration
        let since = pageCache[route]?.at
        let step = try await Task { [api] in try await api.loadStep(page) }.value
        if generation == accountGeneration, pageCache[route]?.at == since {
            if step.whole { pageCache[route]?.page = step.page } else { pageCache[route] = nil }
        }
        return step
    }

    func forget(_ route: Route) {
        pageCache[route] = nil
    }

    /// After the player changed the account's library (a song rated, the queue saved).
    func libraryChanged() {
        for route in [Route.likedSongs, .library, .libraryPlaylists] { forget(route) }
    }

    /// Stands in while YouTube keeps refusing the feed, read off the main actor; nil signed out.
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
