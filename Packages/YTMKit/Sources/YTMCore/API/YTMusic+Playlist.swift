import Foundation

extension YTMusic {
    /// The longest playlist loaded, as ytm-native's `PLAYLIST_LIMIT`.
    static let playlistLimit = 500

    /// A playlist's header and first batch of tracks; `loadMore` adds the
    /// rest a batch at a time, up to `playlistLimit`.
    func playlistPage(_ id: String) async throws -> Page {
        try Renderers.playlistPage(try await playlistResponse(id, asOwner: true), id: id)
    }

    /// A playlist's tracks up to `limit`, following its continuations. A
    /// batch that fails ends the list with what arrived, as rustypipe's
    /// `extend_limit` does for ytm-native.
    func playlistTracks(_ id: String, limit: Int, asOwner: Bool) async throws -> [Track] {
        let shelf = Renderers.trackShelf(in: try await playlistResponse(id, asOwner: asOwner))
        var tracks = Renderers.tracks(shelf["contents"].array)
        var token = Renderers.continuation(shelf)
        while let current = token, tracks.count < limit {
            guard let batch = try await playlistBatch(after: current, asOwner: asOwner), !batch.tracks.isEmpty else { break }
            tracks += batch.tracks
            token = batch.next
        }
        return tracks
    }

    /// The tracks after `token` and the token after them, or nil when the
    /// batch failed for any reason but cancellation.
    func playlistBatch(after token: String, asOwner: Bool) async throws -> (tracks: [Track], next: String?)? {
        do {
            let response = try await asAccount(asOwner) { try await self.innerTube.continuation(token, authenticated: $0) }
            let (items, next) = Renderers.continuationItems(in: response)
            return (Renderers.tracks(items), next)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func playlistResponse(_ id: String, asOwner: Bool) async throws -> JSON {
        try await asAccount(asOwner) { try await self.innerTube.browse("VL" + id, authenticated: $0) }
    }

    /// Runs `request` as the account when `asOwner`, as ytm-native's
    /// `fetch_playlist`: private playlists, Liked music and the radios made
    /// from them exist only for their owner. Should the cookie have gone
    /// stale, public playlists still open signed out; the first failure is
    /// the one reported.
    private func asAccount(_ asOwner: Bool, _ request: (Bool) async throws -> JSON) async throws -> JSON {
        guard asOwner else { return try await request(false) }
        do {
            return try await request(true)
        } catch {
            try Task.checkCancellation()
            guard await auth.isSignedIn, let signedOut = try? await request(false) else { throw error }
            return signedOut
        }
    }
}

extension Renderers {
    /// A playlist page as ytm-native's `playlist` builds it: the header and
    /// the first batch of tracks, with the rest to follow.
    static func playlistPage(_ response: JSON, id: String) throws -> Page {
        let (header, editable) = detailHeader(in: response)
        let shelf = trackShelf(in: response)
        guard header.exists || shelf.exists else {
            throw YTMError(.notFound, "This playlist isn't available.")
        }
        let tracks = tracks(shelf["contents"].array)
        let token = continuation(shelf)
        // The whole list's count is worth reading only when this batch isn't all of it.
        let count = token == nil ? tracks.count : trackCount(header)
        let pageHeader = PageHeader(
            label: "Playlist",
            // Album playlists can come without a header; their tracks name the album.
            title: header["title"].text ?? tracks.first?.album?.name ?? "",
            subtitle: playlistOwner(header) ?? "",
            meta: Formatting.playlistMeta(count: count, tracks: tracks),
            description: description(header),
            thumbnail: Thumbnail.pick(Thumbnail.list(in: header), edge: Thumbnail.header),
            radioId: YTMusic.radioId(forPlaylist: id),
            playlistId: id,
            editable: editable
        )
        return Page(
            header: pageHeader,
            sections: [Section.tracks("", tracks, mode: .section)].compactMap(\.self),
            more: token.flatMap { tracks.isEmpty ? nil : .tracks(token: $0, sectionIndex: 0) }
        )
    }

    /// Who made a playlist: the channel its facepile links to, else the
    /// channel linked in the strapline or subtitle. YouTube Music's own
    /// playlists name none.
    private static func playlistOwner(_ header: JSON) -> String? {
        let facepile = header["facepile", "avatarStackViewModel"]
        guard facepile.exists else {
            return linkedArtists(header.first("straplineTextOne", "subtitle").runs).first?.name
        }
        let onTap = facepile["rendererContext", "commandContext", "onTap", "innertubeCommand"]
        guard case (.artist, _)? = page(onTap) else { return nil }
        return facepile["text", "content"].string
    }
}
