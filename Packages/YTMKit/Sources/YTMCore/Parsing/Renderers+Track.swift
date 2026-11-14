import Foundation

extension Renderers {
    /// A song or video from a `musicResponsiveListItemRenderer`'s body, as
    /// playlists, albums, search results and Quick picks list them. Nil for
    /// rows that open a page (albums, artists, playlists), live streams, and
    /// rows without a video ID or title.
    static func track(_ renderer: JSON, context: ItemContext = ItemContext()) -> Track? {
        if renderer["navigationEndpoint", "browseEndpoint"].exists { return nil }
        let badges = renderer["badges"].array
        if badges.contains(where: { $0["liveBadgeRenderer"].exists }) { return nil }

        let columns = renderer["flexColumns"].array.map(columnText)
        guard let titleRuns = columns.first?.runs, let title = columns.first?.text, !title.isEmpty else { return nil }
        let playButton = renderer["overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint"]
        let watch = playButton.exists ? playButton : titleRuns.first?["navigationEndpoint", "watchEndpoint"] ?? .missing
        guard let id = renderer["playlistItemData", "videoId"].string ?? watch["videoId"].string, !id.isEmpty else { return nil }

        // The columns after the title hold the artists, album, plays and,
        // in search results, the length: found by their links and shapes
        // rather than their order, which differs between lists.
        let details = columns.dropFirst().flatMap(\.runs)
        let segments = columns.dropFirst().flatMap { Renderers.segments($0.runs) }
        var artists = linkedArtists(details)
        if artists.isEmpty { artists = unlinkedArtists(segments) }
        if artists.isEmpty { artists = context.artists }
        let fixed = renderer["fixedColumns"][0]
        let duration = columnText(fixed).text.flatMap(Formatting.seconds)
            ?? segments.lazy.compactMap { Formatting.seconds(text($0)) }.last

        let thumbnails = Thumbnail.list(in: renderer)
        // Without a video type, videos show by their wide thumbnails, as
        // rustypipe tells them; album tracks are songs.
        let first = thumbnails[0]
        let isVideo = isVideo(watch) ?? (context.album == nil && first.exists && first["width"].int != first["height"].int)

        return Track(
            id: id,
            title: title,
            artists: artists,
            album: album(details) ?? context.album,
            duration: duration,
            thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.row),
            trackNumber: renderer["index"].text.flatMap { Int($0) },
            isVideo: isVideo,
            setVideoId: renderer["playlistItemData", "playlistSetVideoId"].string
        )
    }

    /// The text of a flex or fixed column.
    static func columnText(_ column: JSON) -> JSON {
        column.first("musicResponsiveListItemFlexColumnRenderer", "musicResponsiveListItemFixedColumnRenderer")["text"]
    }
}
