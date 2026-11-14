import Foundation

extension YTMusic {
    /// The page behind a route.
    @concurrent
    public func page(_ route: Route) async throws -> Page {
        switch route {
        case .home: try await homePage()
        case .explore: try await explorePage()
        case .library: try await libraryPage()
        case .history: try await historyPage()
        case .search(let query): try await searchPage(query)
        case .album(let id): try await albumPage(id)
        case .playlist(let id): try await playlistPage(id)
        case .artist(let id): try await artistPage(id)
        case .genre(let params): try await genrePage(params: params)
        case .libraryPlaylists, .libraryAlbums, .libraryArtists, .librarySongs: try await libraryListPage(route)
        case .browse(let id, let params): try await browsePage(id, params: params)
        case .newReleases: try await newReleasesPage()
        case .charts: try await chartsPage()
        case .moodsAndGenres: try await moodsAndGenresPage()
        }
    }

    /// Fetches the next step of what `page` has still to show, and leaves
    /// `more` set while there is another, as ytm-native's `complete`: a
    /// playlist's next batch of tracks, or Home's next page of shelves. A
    /// step that fails ends the page with what arrived (and, on Home, the
    /// sections kept for after the shelves); only cancellation throws, so a
    /// page left mid-load is never taken as whole.
    @concurrent
    public func loadMore(_ page: Page) async throws -> Page {
        var page = page
        switch page.more {
        case nil:
            return page
        case .tracks(let token, let index)?:
            page.more = nil
            guard page.sections.indices.contains(index), case .tracks(var section) = page.sections[index],
                  let batch = try await playlistBatch(after: token, asOwner: true)
            else { return page }
            section.tracks += batch.tracks
            page.sections[index] = .tracks(section)
            if let next = batch.next, !batch.tracks.isEmpty, section.tracks.count < Self.playlistLimit {
                page.more = .tracks(token: next, sectionIndex: index)
            }
            if index == 0, let meta = page.header?.meta {
                // The header counts the whole playlist when YouTube said how
                // long it is, else the tracks loaded.
                let count = max(Formatting.number(meta) ?? 0, section.tracks.count)
                page.header?.meta = Formatting.playlistMeta(count: count, tracks: section.tracks)
            }
        case .shelves(let token, let pagesLeft, let trailing)?:
            page.more = nil
            do {
                let (sections, next) = try await homeShelves(token: token)
                page.sections += sections
                if let next, pagesLeft > 1 {
                    page.more = .shelves(token: next, pagesLeft: pagesLeft - 1, trailing: trailing)
                    return page
                }
            } catch {
                try Task.checkCancellation()
            }
            page.sections += trailing
            if await auth.isSignedIn { saveHome(page) }
        }
        return page
    }
}
