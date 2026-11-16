import Foundation

extension Renderers {
    /// An album or playlist page's header renderer, from the two-column page's
    /// first tab or else its own header; owned playlists wrap it as editable.
    static func detailHeader(in response: JSON) -> (renderer: JSON, editable: Bool) {
        let tab = response["contents", "twoColumnBrowseResultsRenderer", "tabs"][0]["tabRenderer", "content", "sectionListRenderer", "contents"][0]
        for wrapper in [tab, response["header"]] {
            let editable = wrapper["musicEditablePlaylistDetailHeaderRenderer", "header"]
            let renderer = (editable.exists ? editable : wrapper).first("musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer")
            if renderer.exists { return (renderer, editable.exists) }
        }
        return (.missing, false)
    }

    static func trackShelf(in response: JSON) -> JSON {
        sectionList(in: response)["contents"].array.lazy
            .map { $0.first("musicShelfRenderer", "musicPlaylistShelfRenderer") }
            .first { $0.exists } ?? .missing
    }

    /// The whole list's track count from a header's second subtitle: "64
    /// songs • 3 hours", or "1B views • 200 songs • 6+ hours".
    static func trackCount(_ header: JSON) -> Int? {
        let parts = segments(header["secondSubtitle"].runs)
        let index = parts.count > 2 ? 1 : 0
        guard parts.indices.contains(index), let first = parts[index].first?["text"].string else { return nil }
        return Formatting.number(first)
    }

    static func description(_ header: JSON) -> String? {
        let description = header["description"]
        let shelf = description["musicDescriptionShelfRenderer", "description"]
        return (shelf.exists ? shelf : description).text.flatMap { $0.isEmpty ? nil : $0 }
    }
}
