import Foundation

// Home, as ytm-native's `api/pages.rs` and `app/navigation.rs` have it: the
// personal feed signed in, saved so it can stand in should every request for
// it fail; the charts and new releases signed out.

extension YTMusic {
    /// Moods & genres chips at the foot of Home.
    private static let homeGenres = 12
    /// Songs in the signed-out Trending list.
    private static let trendingLimit = 10

    /// Signed in, the personal feed from its first shelf, with `more`
    /// fetching the rest below it; once whole, it is saved for `cachedHome`.
    /// Should YouTube keep refusing it, the app shows `homeStandIn`. Signed
    /// out, the charts.
    @concurrent
    func homePage() async throws -> Page {
        guard await auth.isSignedIn else { return try await publicHome() }
        return try await personalHome()
    }

    /// What stands in for a signed-in feed YouTube kept refusing: the feed
    /// as last saved, or with none saved, the charts, as ytm-native's
    /// `show_public_home`. Never kept as Home, so the next visit asks for
    /// the feed again.
    @concurrent
    public func homeStandIn() async -> Page? {
        if let saved = await cachedHome() { return saved }
        return try? await publicHome()
    }

    /// One page of the feed's further shelves, and the token of the next.
    @concurrent
    func homeShelves(token: String) async throws -> (sections: [Section], next: String?) {
        HomeFeed.nextPage(try await homeFeed(continuation: token))
    }

    /// The signed-in Home as last saved, to show in place of the feed when
    /// YouTube keeps refusing it, arranged as a fresh one is, as one saved
    /// by an earlier version may hold other shelves or another order. Reads
    /// the disk, so it runs off the caller's actor.
    @concurrent
    private func cachedHome() async -> Page? {
        guard let saved = store.load(Page.self, from: .home) else { return nil }
        let sections = HomeFeed.arranged(saved.sections)
        return sections.isEmpty ? nil : Page(sections: sections)
    }

    /// Forgets the saved Home, which belongs to the account signed in when
    /// it was saved.
    public func clearCachedHome() {
        store.remove(.home)
    }

    /// Saves the signed-in feed for `cachedHome` once it is whole, as
    /// ytm-native's `save_home`: a first page alone would stand in later as
    /// a shorter, different feed.
    func saveHome(_ page: Page) {
        store.save(Page(sections: page.sections), to: .home)
    }

    /// The feed's shelves that can show (`HomeFeed.release`), reading on
    /// past the first page until one can, as when Speed dial comes later.
    private func personalHome() async throws -> Page {
        var (held, next) = try HomeFeed.firstPage(try await homeFeed(continuation: nil))
        var pagesLeft = HomeFeed.continuations
        var sections = HomeFeed.release(&held, after: [], done: next == nil)
        while sections.isEmpty, let token = next, pagesLeft > 0 {
            let page: (sections: [Section], next: String?)
            do {
                page = try await homeShelves(token: token)
            } catch {
                // A page refused even after its retries is left to `loadStep`
                // with the shelves already read, so the feed keeps its order:
                // asked for again, it carries on, and failing again, it ends
                // with those shelves, flagged as cut short.
                try Task.checkCancellation()
                guard !held.isEmpty else { throw error }
                return Page(sections: [], more: .shelves(token: token, pagesLeft: pagesLeft, held: held))
            }
            held += page.sections
            next = page.next
            pagesLeft -= 1
            sections = HomeFeed.release(&held, after: [], done: next == nil || pagesLeft == 0)
        }
        guard !sections.isEmpty else { throw YTMError(.parse, "YouTube sent an empty Home feed.") }
        if let next, pagesLeft > 0, !HomeFeed.isComplete(sections) {
            return Page(sections: sections, more: .shelves(token: next, pagesLeft: pagesLeft, held: held))
        }
        let page = Page(sections: sections)
        saveHome(page)
        return page
    }

    /// The feed's first page, or the one `token` continues with, asked for
    /// again while YouTube refuses it, up to `HomeFeed.attempts` requests.
    private func homeFeed(continuation token: String?) async throws -> JSON {
        var attempt = 1
        while true {
            do {
                if let token { return try await innerTube.continuation(token) }
                return try await innerTube.browse("FEmusic_home")
            } catch where HomeFeed.isRefusal(error) && attempt < HomeFeed.attempts {
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
