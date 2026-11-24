import Foundation

extension YTMusic {
    private static let homeGenres = 12
    private static let trendingLimit = 10

    /// Signed-in Home's shelves in order, each with its layout (nil for songs), so the app can draw them ahead.
    public static let homeShelves: [(title: String, layout: CardLayout?)] = HomeFeed.shelfOrder.map { title in
        switch title {
        case HomeFeed.speedDialTitle: (title, .speedDial)
        case _ where HomeFeed.songShelves.contains(title): (title, nil)
        default: (title, .carousel)
        }
    }

    /// Signed in, the feed's first shelves with `more` fetching the rest; signed out, the charts.
    /// A dropped connection or an odd answer is asked again for a while, so a blip never brings on the saved feed;
    /// refusals and server errors are already asked again lower down.
    @concurrent
    func homePage() async throws -> Page {
        let start = ContinuousClock.now
        var attempt = 1
        while true {
            do {
                guard await auth.isSignedIn else { return try await publicHome() }
                return try await personalHome()
            } catch where HomeFeed.asksAgain(after: error, attempt: attempt, elapsed: start.duration(to: .now)) {
                try await Task.sleep(for: .seconds(attempt))
                attempt += 1
            }
        }
    }

    /// For a feed YouTube kept refusing: the last saved feed, else the charts. Never kept as Home, so the next visit
    /// asks for the feed again.
    @concurrent
    public func homeStandIn() async -> Page? {
        if let saved = await savedHome() { return saved }
        return try? await publicHome()
    }

    /// The next page; after the first, the next `HomeFeed.atOnce` together, their tokens made from the first's.
    @concurrent
    func homeShelves(token: String, pagesLeft: Int) async throws -> HomeFeed.Pages {
        // Only the first page's token gives the page length.
        guard pagesLeft == HomeFeed.continuations, let tokens = HomeFeed.laterTokens(token) else {
            let page = HomeFeed.nextPage(try await homeFeed(continuation: token))
            return (page.sections, page.next, 1)
        }
        let answers = await withTaskGroup(of: (Int, Result<HomeFeed.Shelves, any Error>).self) { group in
            for (index, token) in tokens.enumerated() {
                // The first is YouTube's own token, so it gets every attempt.
                let attempts = index == 0 ? HomeFeed.attempts : HomeFeed.madePageAttempts
                group.addTask {
                    do {
                        return (index, .success(HomeFeed.nextPage(try await self.homeFeed(continuation: token, attempts: attempts))))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var answers = [Result<HomeFeed.Shelves, any Error>?](repeating: nil, count: tokens.count)
            for await (index, answer) in group {
                answers[index] = answer
                // The pages after it would be thrown away, so they stop.
                if HomeFeed.isCutShort(tokens, answers) { group.cancelAll() }
            }
            return answers.compactMap(\.self)
        }
        // Else a later page cut short by cancellation would read as one to fetch again.
        try Task.checkCancellation()
        return try HomeFeed.batch(tokens, answers)
    }

    /// Arranged as a fresh one is, since one saved by an earlier version may hold other shelves or another order.
    @concurrent
    private func savedHome() async -> Page? {
        guard let saved = store.load(Page.self, from: .home) else { return nil }
        let sections = HomeFeed.arranged(saved.sections)
        return sections.isEmpty ? nil : Page(sections: sections)
    }

    /// The visitor ID belongs to the account it was given to.
    public func forgetVisitorData() async {
        await innerTube.forgetVisitorData()
    }

    /// The saved Home and Library belong to the account they were saved under. Not async, so a read or save asked
    /// for after it comes after it.
    public func forgetSavedPages() {
        store.remove(.home)
        store.remove(.library)
    }

    /// Only once whole: a first page alone would stand in later as a shorter, different feed.
    public func saveHome(_ page: Page) {
        store.save(Page(sections: page.sections), to: .home)
    }

    /// Reads on past the first page until a shelf can show, as when Speed dial comes later.
    private func personalHome() async throws -> Page {
        var (held, next) = try HomeFeed.firstPage(try await homeFeed(continuation: nil))
        var pagesLeft = HomeFeed.continuations
        var sections = HomeFeed.release(&held, after: [], done: next == nil)
        while sections.isEmpty, let token = next, pagesLeft > 0 {
            let page: HomeFeed.Pages
            do {
                page = try await homeShelves(token: token, pagesLeft: pagesLeft)
            } catch {
                // Left to `loadStep` with the shelves read so far, so the feed keeps its order.
                try Task.checkCancellation()
                guard !held.isEmpty else { throw error }
                return Page(sections: [], more: .shelves(token: token, pagesLeft: pagesLeft, held: held))
            }
            held += page.sections
            next = page.next
            pagesLeft -= page.pages
            sections = HomeFeed.release(&held, after: [], done: next == nil || pagesLeft <= 0)
        }
        guard !sections.isEmpty else { throw YTMError(.parse, "YouTube sent an empty Home feed.") }
        if let next, pagesLeft > 0, !HomeFeed.isComplete(sections) {
            return Page(sections: sections, more: .shelves(token: next, pagesLeft: pagesLeft, held: held))
        }
        return Page(sections: sections)
    }

    /// Asked again while YouTube refuses it, up to `attempts` times.
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

    /// Only the charts must arrive.
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

    /// From the trending playlist, as the chart lists come empty; none should it fail.
    private func trendingTracks(_ charts: Charts) async -> [Track] {
        guard let id = charts.trendingPlaylistId else { return charts.trendingTracks }
        return (try? await playlistTracks(id, limit: Self.trendingLimit, asOwner: false)) ?? []
    }

    private func genreChips() async -> Section? {
        guard let chips = try? await moodsAndGenres() else { return nil }
        return .cards("Browse moods & genres", Array(chips.all.prefix(Self.homeGenres)), layout: .chips)
    }
}
