import Foundation

extension YTMusic {
    /// The radio YouTube Music plays for a radio's playlist ID, as an
    /// artist page's radio button or a playlist's (`RDAMPL` + its ID) names
    /// it. Asked as the account when signed in, so radios of private
    /// playlists play.
    @concurrent
    public func radio(playlistId: String) async throws -> [Track] {
        let next = try await innerTube.next(["playlistId": playlistId, "params": Self.radioParams], authenticated: true)
        return try Renderers.queue(in: next)
    }

    /// The radio YouTube Music plays after a song: 50 tracks, without the
    /// song itself, which callers queue first. Asked signed out, as
    /// ytm-native does.
    @concurrent
    public func radio(videoId: String) async throws -> [Track] {
        let next = try await innerTube.next(["playlistId": "RDAMVM" + videoId, "params": Self.radioParams], authenticated: false)
        return try Renderers.queue(in: next)
    }

    /// The radio's playlist ID for a playlist or album's own.
    static func radioId(forPlaylist id: String) -> String { "RDAMPL" + id }

    /// The params YouTube Music's player starts a radio with, as rustypipe's
    /// `music_radio` sends them.
    private static let radioParams = "wAEB8gECeAE%3D"
}

extension InnerTube {
    /// The `next` endpoint as YouTube Music's player asks it: the queue
    /// panel for `target` (a `videoId` or `playlistId`), and the song's
    /// Lyrics and Related tabs.
    func next(_ target: [String: String], authenticated: Bool) async throws -> JSON {
        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        body.merge(target) { $1 }
        return try await post("next", body: body, authenticated: authenticated)
    }
}

extension Renderers {
    /// The tabs of a `next` response: Up next, Lyrics and Related.
    static func watchNextTabs(_ next: JSON) -> [JSON] {
        next["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs"]
            .array.map { $0["tabRenderer"] }
    }

    /// The queue panel's tracks of a `next` response, as rustypipe's
    /// `music_radio` reads them. Fails when there is no queue, which is how
    /// YouTube answers for a radio it can't make.
    static func queue(in next: JSON) throws -> [Track] {
        guard let panel = watchNextTabs(next).lazy
            .map({ $0["content", "musicQueueRenderer", "content", "playlistPanelRenderer"] })
            .first(where: \.exists)
        else { throw YTMError(.notFound, "YouTube has no radio for this.") }
        return panel["contents"].array.compactMap { item in
            // Signed in, a song with a music video comes wrapped with it;
            // the song is the primary one.
            let direct = item["playlistPanelVideoRenderer"]
            return queueTrack(direct.exists ? direct : item["playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"])
        }
    }

    /// A `playlistPanelVideoRenderer`, as rustypipe's `map_queue_item`: the
    /// byline's first part names the artists and, for songs, the second
    /// the album.
    static func queueTrack(_ renderer: JSON) -> Track? {
        guard let id = renderer["videoId"].string, !id.isEmpty,
              let title = renderer["title"].text, !title.isEmpty
        else { return nil }
        let segments = segments(renderer["longBylineText"].runs)
        let byline = segments.first ?? []
        var artists = linkedArtists(byline)
        if artists.isEmpty { artists = unlinkedArtists([byline]) }

        let thumbnails = renderer["thumbnail", "thumbnails"]
        let first = thumbnails[0]
        // Without a video type, videos show by their wide thumbnails, and an
        // item without any counts as one, as rustypipe tells them.
        let isVideo = isVideo(renderer["navigationEndpoint", "watchEndpoint"])
            ?? !(first.exists && first["width"].int == first["height"].int)

        return Track(
            id: id,
            title: title,
            artists: artists,
            album: isVideo ? nil : segments.dropFirst().first.flatMap(album),
            duration: renderer["lengthText"].text.flatMap(Formatting.seconds),
            thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.row),
            isVideo: isVideo
        )
    }
}
