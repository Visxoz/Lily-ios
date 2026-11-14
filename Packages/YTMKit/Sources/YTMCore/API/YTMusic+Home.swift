import Foundation

// Home, as ytm-native's `api/pages.rs` and `app/navigation.rs` have it: the
// personal feed signed in, saved so it can stand in when YouTube refuses it;
// the charts and new releases signed out.

extension YTMusic {
    /// Moods & genres chips at the foot of Home.
    private static let homeGenres = 12
    /// Songs in the signed-out Trending list.
    private static let trendingLimit = 10
    /// The wait after the signed-in feed's first try was refused, before the
    /// retries: refusals come in bursts, so asking again at once would likely
    /// be refused too, as ytm-native's `HOME_RETRY_AFTER`.
    public static let homeRetryAfter = HomeFeed.retryDelay(after: 1)

    /// Signed in, the personal feed's first page, with `more` fetching the
    /// next ones and the moods & genres chips after them; it is saved for
    /// `cachedHome`. Should YouTube keep refusing the feed with no saved one
    /// to show instead, the charts stand in, as in ytm-native. Signed out,
    /// the charts.
    @concurrent
    func homePage() async throws -> Page {
        guard await auth.isSignedIn else { return try await publicHome() }
        do {
            return try await personalHome()
        } catch {
            guard !Task.isCancelled, cachedHome() == nil, let page = try? await publicHome() else { throw error }
            return page
        }
    }

    /// The signed-in feed in one request, saved as `homePage` saves it, so
    /// the app can show the saved feed at once when YouTube refuses it rather
    /// than wait out the retries, as ytm-native's `home_first_try`. No charts
    /// stand in.
    @concurrent
    public func homeFirstTry() async throws -> Page {
        try await personalHome(attempts: 1)
    }

    /// One page of the feed's further shelves, and the token of the next.
    @concurrent
    func homeShelves(token: String) async throws -> (sections: [Section], next: String?) {
        HomeFeed.nextPage(try await homeFeed(continuation: token))
    }

    /// The signed-in Home as last saved, to show in place of the feed when
    /// YouTube refuses it. Reads the disk, so call it off the main actor.
    public func cachedHome() -> Page? {
        store.load(Page.self, from: .home).flatMap { $0.sections.isEmpty ? nil : $0 }
    }

    /// Forgets the saved Home, which belongs to the account signed in when
    /// it was saved.
    public func clearCachedHome() {
        store.remove(.home)
    }

    /// Saves the signed-in feed as far as it has loaded, with the sections
    /// still to follow it, for `cachedHome`: its first page as soon as it
    /// arrives, and the whole feed once `loadMore` has completed it, as
    /// ytm-native's `save_home`.
    func saveHome(_ page: Page) {
        var sections = page.sections
        if case .shelves(_, _, let trailing)? = page.more { sections += trailing }
        store.save(Page(sections: sections), to: .home)
    }

    private func personalHome(attempts: Int = HomeFeed.attempts) async throws -> Page {
        async let genres = genreChips()
        let (sections, next) = try HomeFeed.firstPage(try await homeFeed(continuation: nil, attempts: attempts))
        guard !sections.isEmpty else { throw YTMError(.parse, "YouTube sent an empty Home feed.") }
        let trailing = await genres.map { [$0] } ?? []
        let page = next.map {
            Page(sections: sections, more: .shelves(token: $0, pagesLeft: HomeFeed.continuations, trailing: trailing))
        } ?? Page(sections: sections + trailing)
        saveHome(page)
        return page
    }

    /// The feed's first page, or the one `token` continues with, asked for
    /// again while YouTube refuses it, up to `attempts` requests in all.
    private func homeFeed(continuation token: String?, attempts: Int = HomeFeed.attempts) async throws -> JSON {
        var attempt = 1
        while true {
            do {
                if let token { return try await innerTube.continuation(token) }
                return try await innerTube.browse("FEmusic_home")
            } catch where HomeFeed.isRefusal(error) && attempt < attempts {
                try await Task.sleep(for: HomeFeed.retryDelay(after: attempt))
                attempt += 1
            }
        }
    }

    /// Home for everyone: what's trending, new releases, the top artists
    /// and the first moods & genres. Only the charts are needed.
    private func publicHome() async throws -> Page {
        async let albums = newAlbums()
        async let genres = genreChips()
        let charts = try await charts()
        let trending = await trendingTracks(charts)
        let sections: [Section?] = [
            .tracks("Trending", Array(trending.prefix(Self.trendingLimit)), mode: .section),
            .cards("New releases", Array(await albums.prefix(Self.shelfLimit)), layout: .carousel),
            .cards("Top artists", Array(charts.artists.prefix(Self.shelfLimit)), layout: .carousel),
            await genres,
        ]
        return Page(sections: sections.compactMap(\.self))
    }

    /// The trending songs: the trending playlist's, as the chart lists come
    /// empty nowadays, or the chart's own when there is no such playlist.
    /// None should the playlist fail.
    private func trendingTracks(_ charts: Charts) async -> [Track] {
        guard let id = charts.trendingPlaylistId else { return charts.trendingTracks }
        return (try? await playlistTracks(id, limit: Self.trendingLimit, asOwner: false)) ?? []
    }

    /// The first moods & genres chips; none should they fail to load.
    private func genreChips() async -> Section? {
        guard let chips = try? await moodsAndGenres() else { return nil }
        return .cards("Browse moods & genres", Array(chips.all.prefix(Self.homeGenres)), layout: .chips)
    }
}
