import Foundation

extension YTMusic {
    /// Each kind from its own filtered search, all at once. Only the songs must arrive; any other kind that fails is
    /// left out, unretried, as the page waits for every kind and a retry waits seconds.
    func searchPage(_ query: String) async throws -> Page {
        async let top = try? topResult(query)
        async let songs = search(query, .songs)
        // Uploads too: slowed and sped-up edits, mashups and live versions are videos, not songs, on YouTube Music.
        async let videos = try? search(query, .videos, retries: 0)
        async let artists = try? search(query, .artists, retries: 0)
        async let albums = try? search(query, .albums, retries: 0)
        async let playlists = try? search(query, .playlists, retries: 0)
        let sections = try await [top, songs, videos, artists, albums, playlists].compactMap(\.self)
        guard !sections.isEmpty else { throw YTMError(.notFound, "No results for \u{201C}\(query)\u{201D}") }
        return Page(sections: sections)
    }

    func search(_ query: String, _ kind: SearchKind, retries: Int = InnerTube.retries) async throws -> Section? {
        try await shelf(query, kind, layout: .carousel, retries: retries)?.section.retitled(kind.title)
    }

    /// One kind in full: the first batch now, the rest as `Page.more` steps.
    func searchPage(_ query: String, _ kind: SearchKind) async throws -> Page {
        guard let (section, shelf) = try await shelf(query, kind, layout: .grid, retries: InnerTube.retries) else {
            throw YTMError(.notFound, "No \(kind.title.lowercased()) for \u{201C}\(query)\u{201D}")
        }
        let more = Renderers.continuation(shelf).map { Continuation.search(token: $0, stepsLeft: Self.searchSteps) }
        return Page(sections: [section.retitled("")], more: more)
    }

    /// YouTube ends a kind's list itself, at around 30 steps for a popular artist's songs; this only stops one that
    /// never ends.
    private static let searchSteps = 50

    /// The kind's shelf, parsed and as sent, so its continuation can be read.
    private func shelf(
        _ query: String, _ kind: SearchKind, layout: CardLayout, retries: Int
    ) async throws -> (section: Section, shelf: JSON)? {
        let response = try await innerTube.post(
            "search", body: ["query": query, "params": kind.params], authenticated: false, retries: retries
        )
        for wrapped in Renderers.sectionList(in: response)["contents"].array {
            if let (_, shelf) = wrapped.onlyValue, let section = Renderers.section(wrapped, mode: .radio, layout: layout) {
                return (section, shelf)
            }
        }
        return nil
    }

    /// Only when YouTube Music leads with an artist, album or playlist; a song or video in the lead shows among the
    /// others.
    private func topResult(_ query: String) async throws -> Section? {
        let response = try await innerTube.post("search", body: ["query": query], authenticated: false)
        guard let lead = Renderers.section(Renderers.sectionList(in: response)["contents"][0]),
              case .cards(let cards) = lead, cards.layout == .top
        else { return nil }
        return lead
    }
}

public enum SearchKind: String, Codable, CaseIterable, Sendable {
    case songs, videos, artists, albums, playlists

    var params: String {
        switch self {
        case .songs: "EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        case .videos: "EgWKAQIQAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        case .albums: "EgWKAQIYAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        case .artists: "EgWKAQIgAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        // YouTube Music's own playlists.
        case .playlists: "EgeKAQQoADgBahIQAxAEEAkQDhAKEAUQERAQEBU%3D"
        }
    }

    public var title: String {
        switch self {
        case .songs: "Songs"
        case .videos: "Videos"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        }
    }
}

extension Section {
    /// Drops the "Show all" a search shelf links to.
    func retitled(_ title: String) -> Section {
        switch self {
        case .tracks(var section):
            section.title = title
            section.more = nil
            return .tracks(section)
        case .cards(var section):
            section.title = title
            section.more = nil
            return .cards(section)
        }
    }
}
