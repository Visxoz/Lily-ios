import Foundation

extension YTMusic {
    static let playlistLimit = 500

    /// The first batch; `loadMore` adds the rest, up to `playlistLimit`.
    func playlistPage(_ id: String) async throws -> Page {
        try Renderers.playlistPage(try await playlistResponse(id, asOwner: true), id: id)
    }

    /// A batch that fails ends the list with what arrived, unless `whole`, when it throws instead.
    func playlistTracks(_ id: String, limit: Int, asOwner: Bool, whole: Bool = false) async throws -> [Track] {
        let shelf = Renderers.trackShelf(in: try await playlistResponse(id, asOwner: asOwner))
        var tracks = Renderers.tracks(shelf["contents"].array)
        var token = Renderers.continuation(shelf)
        while let current = token, tracks.count < limit {
            guard let batch = try await playlistBatch(after: current, asOwner: asOwner) else {
                if whole { throw YTMError(.network, "The whole playlist couldn't be loaded.") }
                break
            }
            guard !batch.tracks.isEmpty else { break }
            tracks += batch.tracks
            token = batch.next
        }
        return tracks
    }

    /// Nil when the batch failed for any reason but cancellation. `entries` keeps each song's entry ID, for the
    /// account's own playlist.
    func playlistBatch(after token: String, asOwner: Bool, entries: Bool = false) async throws -> (tracks: [Track], next: String?)? {
        do {
            let response = try await asAccount(asOwner) { try await self.innerTube.continuation(token, authenticated: $0) }.response
            let (items, next) = Renderers.continuationItems(in: response)
            return (Renderers.tracks(items, context: ItemContext(entries: entries)), next)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func playlistResponse(_ id: String, asOwner: Bool) async throws -> JSON {
        try await asAccount(asOwner) { try await self.innerTube.browse("VL" + id, authenticated: $0) }.response
    }

    /// Private playlists, Liked music and their radios exist only for their owner, and only the account's own
    /// requests say what is in its library; with a stale cookie, public pages still open signed out. The first
    /// failure is the one reported. `signedIn` says whether the answer was the account's, which a request without
    /// a cookie, the signed-out fallback and an answer YouTube served signed out are not.
    func asAccount(_ asOwner: Bool, _ request: (Bool) async throws -> JSON) async throws -> (response: JSON, signedIn: Bool) {
        guard asOwner else { return (try await request(false), false) }
        let signedIn = await auth.isSignedIn
        do {
            let response = try await request(true)
            return (response, signedIn && !Renderers.answeredSignedOut(response))
        } catch {
            try Task.checkCancellation()
            guard await auth.isSignedIn, let signedOut = try? await request(false) else { throw error }
            return (signedOut, false)
        }
    }
}

extension Renderers {
    static func playlistPage(_ response: JSON, id: String) throws -> Page {
        let header = detailHeader(in: response)
        let shelf = trackShelf(in: response)
        guard header.exists || shelf.exists else {
            throw YTMError(.notFound, "This playlist isn't available.")
        }
        let ownership = ownership(in: response)
        // Only those the account made take edits, not Liked music or the mixes.
        let own = ownership.editable && id.hasPrefix("PL")
        let tracks = tracks(shelf["contents"].array, context: ItemContext(entries: own))
        let token = continuation(shelf)
        // The whole list's count is worth reading only when this batch isn't all of it.
        let count = token == nil ? tracks.count : trackCount(header)
        var pageHeader = PageHeader(
            label: "Playlist",
            // Album playlists can come without a header; their tracks name the album.
            title: header["title"].text ?? tracks.first?.album?.name ?? "",
            subtitle: playlistOwner(header) ?? "",
            meta: Formatting.playlistMeta(count: count, tracks: tracks),
            description: description(header),
            thumbnail: Thumbnail.pick(Thumbnail.list(in: header), edge: Thumbnail.header),
            radioId: YTMusic.radioId(forPlaylist: id),
            playlistId: id
        )
        pageHeader.count = count
        if own {
            pageHeader.editable = true
            pageHeader.privacy = ownership.privacy
        }
        pageHeader.saved = saved(header)
        pageHeader.saveId = pageHeader.saved.map { _ in id }
        return Page(
            header: pageHeader,
            sections: [Section.tracks("", tracks, mode: .section)].compactMap(\.self),
            more: token.flatMap { tracks.isEmpty ? nil : .tracks(token: $0) }
        )
    }

    /// The channel the facepile links to, else the one in the strapline or
    /// subtitle. YouTube Music's own playlists name none.
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
