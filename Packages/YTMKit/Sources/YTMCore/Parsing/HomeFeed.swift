import Foundation

/// The signed-in Home feed (`FEmusic_home`): shelves such as Listen again,
/// Quick picks and Mixed for you, a port of ytm-native's `api/home_feed.rs`.
/// Its carousels, song lists and grids are read by the shared shelf parser,
/// with subtitles as YouTube words them.
enum HomeFeed {
    /// Requests made for one page of the feed before giving up.
    static let attempts = 4
    /// Pages fetched at most after the first; the whole feed is five or six,
    /// and the shelves Home keeps come from any of them.
    static let continuations = 8
    /// Longest list shelf shown, such as Quick picks.
    static let listLimit = 10
    /// The web feed's Listen again, which YouTube's phone apps show as
    /// Speed dial: theirs leads to the same page, and the web has no other.
    static let speedDialId = "FEmusic_listen_again"
    /// The title it shows under, as on YouTube's phone apps.
    static let speedDialTitle = "Speed dial"
    /// Its titles, for the feed as usually sent, whose title leads nowhere.
    /// The feed is always asked for in English (`InnerTube.language`).
    private static let speedDialTitles: Set<String> = ["Listen again", speedDialTitle]
    /// The shelves Home shows, in this order, as ytm-native's `SHELVES`:
    /// those made from the account's own listening. The rest, such as
    /// charts, community playlists, new releases and recaps, are left out.
    static let shelfOrder = [
        speedDialTitle, "Quick picks", "Forgotten favorites", "Trending songs for you", "Mixed for you",
        "Fresh finds, old favorites",
    ]
    /// The latest plays put before YouTube's Speed dial, which seldom has
    /// them: few, so its own picks still fill most of the first page.
    static let recentPlays = 3
    /// Plays that make Speed dial when the feed has none: a first page beside the die.
    static let recentShelf = 8
    /// The shelves the feed lists songs or tiles in: carousels, and the
    /// song lists and grids it mixes in among them.
    private static let shelfKinds: Set<String> = [
        "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer", "musicShelfRenderer", "gridRenderer",
    ]

    /// YouTube refuses a share of requests for the signed-in feed, in bursts,
    /// with "400: Request contains an invalid argument", and answers the same
    /// request a moment later. The rest of the account, and the feed signed
    /// out, are unaffected, so it is YouTube building the feed that fails.
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? YTMError)?.status == 400
    }

    /// How long to wait before asking again after `attempt` was refused.
    static func retryDelay(after attempt: Int) -> Duration {
        .milliseconds(300 * attempt)
    }

    /// The first page's shelves and the token of the next page.
    static func firstPage(_ response: JSON) throws -> (sections: [Section], next: String?) {
        let list = response["contents", "singleColumnBrowseResultsRenderer", "tabs"][0]["tabRenderer", "content", "sectionListRenderer"]
        guard list.exists else { throw YTMError(.parse, "YouTube sent Home in a shape the app doesn't know.") }
        return (shelves(list), Renderers.continuation(list))
    }

    /// A continuation page's shelves and the token of the one after; none
    /// when the response has no more of the feed.
    static func nextPage(_ response: JSON) -> (sections: [Section], next: String?) {
        let list = response["continuationContents", "sectionListContinuation"]
        return (shelves(list), Renderers.continuation(list))
    }

    /// The shelves of a section list, each a card row or grid or, when it
    /// lists songs, a track list of at most `listLimit`. Other shelves (the
    /// taste picker, banners) are skipped.
    private static func shelves(_ list: JSON) -> [Section] {
        let context = ItemContext(subtitles: .asShown, musicVideosOnly: true)
        return list["contents"].array.compactMap { wrapped -> Section? in
            guard let kind = wrapped.onlyValue?.key, shelfKinds.contains(kind) else { return nil }
            switch Renderers.section(wrapped, context: context) {
            case .tracks(var shelf)?:
                shelf.tracks = Array(shelf.tracks.prefix(listLimit))
                return .tracks(shelf)
            case let section?:
                return asSpeedDial(section)
            case nil:
                return nil
            }
        }
    }

    /// Listen again as Speed dial; any other section as it is.
    private static func asSpeedDial(_ section: Section) -> Section {
        guard case .cards(var shelf) = section, isSpeedDial(shelf), !shelf.cards.isEmpty else { return section }
        shelf.title = speedDialTitle
        shelf.layout = .speedDial
        return .cards(shelf)
    }

    /// Listen again, by the page its title leads to, or else by its title.
    private static func isSpeedDial(_ shelf: CardSection) -> Bool {
        if case .browse(let id, _)? = shelf.more, id == speedDialId { return true }
        return speedDialTitles.contains(shelf.title)
    }

    /// The shelves to show after `shown`, taken from `held`, the shelves read
    /// but not yet shown, as ytm-native's `Feed::release`. YouTube orders
    /// them differently on every load, so each in `shelfOrder` is held back
    /// until every one above it has arrived: Home fills from the top down,
    /// always in one order, and never moves what is already on screen. Once
    /// the feed has ended (`done`), whatever of `shelfOrder` is left, and
    /// nothing else; unless none of it came, as when YouTube renames them,
    /// when the feed is kept whole rather than left empty. Songs from a list
    /// shelf such as Quick picks play with a radio after them, as YouTube
    /// Music does, rather than the shelf's ten on their own.
    static func release(_ held: inout [Section], after shown: [Section], done: Bool) -> [Section] {
        var out: [Section] = []
        if done, shown.isEmpty, !held.contains(where: { shelfOrder.contains($0.title) }) {
            out = held
            held = []
        }
        for title in shelfOrder {
            guard !(shown + out).contains(where: { $0.title == title }) else { continue }
            if let index = held.firstIndex(where: { $0.title == title }) {
                out.append(held.remove(at: index))
            } else if !done {
                break
            }
        }
        if done { held = [] }
        return out.map { section in
            guard case .tracks(var shelf) = section else { return section }
            shelf.mode = .radio
            return .tracks(shelf)
        }
    }

    /// Whether every shelf Home shows has arrived, after which nothing later in the feed can show.
    static func isComplete(_ sections: [Section]) -> Bool {
        shelfOrder.allSatisfy { title in sections.contains { $0.title == title } }
    }

    /// A whole feed, such as the saved one, as `release` shows it; one saved
    /// by an earlier version has Listen again under that name.
    static func arranged(_ sections: [Section]) -> [Section] {
        var held = sections.map(asSpeedDial)
        return release(&held, after: [], done: true)
    }

    /// Puts the latest `recentPlays` of `recent`, songs played newest first,
    /// before Speed dial's own picks, which all stay, in YouTube's order; one
    /// it already has stays where YouTube put it. With no Speed dial in the
    /// feed, the shelf is made of the latest `recentShelf` instead.
    static func recentFirst(_ sections: [Section], recent: [Track]) -> [Section] {
        var sections = sections
        guard let index = sections.firstIndex(where: { if case .cards(let s) = $0 { s.layout == .speedDial } else { false } }),
              case .cards(var shelf) = sections[index]
        else {
            let cards = recent.prefix(recentShelf).map(card)
            if !cards.isEmpty { sections.insert(.cards(CardSection(title: speedDialTitle, cards: cards, layout: .speedDial)), at: 0) }
            return sections
        }
        let picked = Set(shelf.cards.map(\.id))
        let fresh = recent.prefix(recentPlays).filter { !picked.contains($0.id) }.map(card)
        guard !fresh.isEmpty else { return sections }
        shelf.cards = fresh + shelf.cards
        sections[index] = .cards(shelf)
        return sections
    }

    /// A song played, as a Speed dial tile.
    private static func card(_ track: Track) -> Card {
        Card(
            kind: .song, id: track.id, title: track.title, subtitle: track.artistNames,
            thumbnail: track.thumbnail.map { Thumbnail.resized($0, edge: Thumbnail.card) }, track: track
        )
    }
}

extension Page {
    /// Home with the latest few of `recent`, songs played on this phone
    /// newest first, before Speed dial's own picks (`HomeFeed.recentFirst`):
    /// applied as it shows rather than as it loads, so a Home from the cache
    /// or the disk leads with what played since too.
    public func leadingWithRecentPlays(_ recent: [Track]) -> Page {
        Page(header: header, sections: HomeFeed.recentFirst(sections, recent: recent), more: more)
    }
}
