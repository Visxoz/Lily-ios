import Foundation

/// The signed-in Home feed (`FEmusic_home`): shelves such as Listen again,
/// Quick picks and Mixed for you, a port of ytm-native's `api/home_feed.rs`.
/// Its carousels, song lists and grids are read by the shared shelf parser,
/// with subtitles as YouTube words them.
enum HomeFeed {
    /// Requests made for one page of the feed before giving up.
    static let attempts = 4
    /// Pages fetched after the first, as YouTube Music loads while scrolling.
    static let continuations = 2
    /// Longest list shelf shown, such as Quick picks.
    static let listLimit = 10
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
            case let section:
                return section
            }
        }
    }
}
