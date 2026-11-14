import Foundation

extension Renderers {
    /// A shelf in its `{"<kind>Renderer": {...}}` wrapper as one section:
    /// carousels, lists (`musicShelfRenderer`, `musicPlaylistShelfRenderer`),
    /// grids, and the top search result (`musicCardShelfRenderer`).
    ///
    /// A shelf with songs is a track list, played as `mode` says; otherwise
    /// its cards are, laid out as `layout`, or by the shelf's kind (grids as
    /// grids, genre chips as chips, the rest as carousels). Nil for other
    /// shelves and for empty ones.
    static func section(
        _ wrapped: JSON, context: ItemContext = ItemContext(), mode: QueueMode = .section, layout: CardLayout? = nil
    ) -> Section? {
        guard let (key, shelf) = wrapped.onlyValue else { return nil }
        let title: String
        let items: [JSON]
        var more: Route?
        var shelfLayout = CardLayout.carousel
        switch key {
        case "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer":
            let header = shelf["header"].onlyValue?.value ?? .missing
            title = header["title"].text ?? ""
            items = shelf["contents"].array
            let button = header["moreContentButton", "buttonRenderer", "navigationEndpoint"]
            more = route(button.exists ? button : header["title"].runs.first?["navigationEndpoint"] ?? .missing)
        case "musicShelfRenderer", "musicPlaylistShelfRenderer":
            title = shelf["title"].text ?? ""
            items = shelf["contents"].array
            more = route(shelf["bottomEndpoint"])
        case "gridRenderer":
            title = shelf["header", "gridHeaderRenderer", "title"].text ?? ""
            items = shelf["items"].array
            shelfLayout = .grid
        case "musicCardShelfRenderer":
            return topResultCard(shelf).flatMap { .cards("Top result", [$0], layout: .top) }
        default:
            return nil
        }

        var tracks: [Track] = []
        var cards: [Card] = []
        for item in items {
            switch Renderers.item(item, context: context) {
            case .track(let track)?: tracks.append(track)
            case .card(let card)?: cards.append(card)
            case nil: break
            }
        }
        if !tracks.isEmpty {
            return .tracks(title, tracks, mode: mode, numbered: context.album != nil, more: more)
        }
        let chips = cards.allSatisfy { $0.kind == .genre }
        return .cards(title, cards, layout: layout ?? (chips ? .chips : shelfLayout), more: more)
    }

    /// The sections of a section list's `contents`, skipping shelves that
    /// can't be read.
    static func sections(
        _ sectionList: JSON, context: ItemContext = ItemContext(), mode: QueueMode = .section, layout: CardLayout? = nil
    ) -> [Section] {
        sectionList["contents"].array.compactMap { section($0, context: context, mode: mode, layout: layout) }
    }

    /// A browse or search response's section list, first page or
    /// continuation, whichever layout the page came in.
    static func sectionList(in response: JSON) -> JSON {
        let contents = response["contents"]
        let tab = { (renderer: JSON) in renderer["tabs"][0]["tabRenderer", "content", "sectionListRenderer"] }
        for candidate in [
            tab(contents["singleColumnBrowseResultsRenderer"]),
            contents["twoColumnBrowseResultsRenderer", "secondaryContents", "sectionListRenderer"],
            tab(contents["tabbedSearchResultsRenderer"]),
            response["continuationContents", "sectionListContinuation"],
        ] where candidate.exists {
            return candidate
        }
        return .missing
    }

    /// The token of the next page of a shelf, grid or section list (its
    /// unwrapped body): `continuations`' next continuation, or a trailing
    /// `continuationItemRenderer`.
    static func continuation(_ renderer: JSON) -> String? {
        let data = renderer["continuations"][0].first("nextContinuationData", "nextRadioContinuationData")
        if let token = data["continuation"].string, !token.isEmpty { return token }
        return trailingToken(renderer.first("contents", "items"))
    }

    /// A continuation response's items and the token after them, from
    /// `continuationContents` (shelves, grids, section lists, the radio panel)
    /// or `onResponseReceivedActions`' appended items.
    static func continuationItems(in response: JSON) -> (items: [JSON], token: String?) {
        if let (_, renderer) = response["continuationContents"].onlyValue {
            return (renderer.first("contents", "items").array, continuation(renderer))
        }
        let items = response["onResponseReceivedActions"].array.lazy
            .map { $0["appendContinuationItemsAction", "continuationItems"] }
            .first { $0.exists } ?? .missing
        return (items.array, trailingToken(items))
    }

    /// The token of a list's trailing `continuationItemRenderer`.
    private static func trailingToken(_ items: JSON) -> String? {
        token(items.last["continuationItemRenderer", "continuationEndpoint"])
    }
}
