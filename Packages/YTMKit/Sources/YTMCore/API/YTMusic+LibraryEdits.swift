import Foundation

/// Changes to the signed-in account's music: likes, dislikes, its own
/// playlists and its saved albums and playlists, through the calls YouTube
/// Music's website makes, as ytm-native's `api/library.rs`.
extension YTMusic {
    /// Video IDs YouTube takes in one playlist call.
    private static let perRequest = 100

    /// The account's rating of a song, from its like button. Signed out,
    /// there is none to ask for.
    @concurrent
    public func rating(videoId: String) async throws -> Rating {
        guard await auth.isSignedIn else { return .none }
        return Rating(next: try await innerTube.post("next", body: ["videoId": videoId]))
    }

    @concurrent
    public func rate(videoId: String, _ rating: Rating) async throws {
        let endpoint = switch rating {
        case .like: "like/like"
        case .dislike: "like/dislike"
        case .none: "like/removelike"
        }
        _ = try await edit(endpoint, ["target": ["videoId": videoId]])
    }

    /// The account's own playlists, marking those that hold the song.
    @concurrent
    public func playlists(adding videoId: String) async throws -> [PlaylistOption] {
        let reply = try await edit("playlist/get_add_to_playlist", ["videoIds": [videoId]])
        guard let options = PlaylistOption.list(in: reply) else {
            throw YTMError(.parse, "YouTube didn't list your playlists.")
        }
        return options
    }

    /// Adds the songs to the end of one of the account's playlists.
    @concurrent
    public func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws {
        try await editPlaylist(playlistId, actions: videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0] })
    }

    /// Removes the entries from one of the account's playlists, by each
    /// entry's own ID, so only the one copy chosen goes.
    @concurrent
    public func removeFromPlaylist(_ playlistId: String, tracks: [Track]) async throws {
        let actions = tracks.compactMap { track in
            track.setVideoId.map { ["action": "ACTION_REMOVE_VIDEO", "setVideoId": $0, "removedVideoId": track.id] }
        }
        guard actions.count == tracks.count else {
            throw YTMError(.notFound, "These songs can't be removed: the playlist didn't say where they are.")
        }
        try await editPlaylist(playlistId, actions: actions)
    }

    /// Makes a private playlist of the songs and returns its ID. Large
    /// playlists are filled in after creation, as the create call takes only
    /// so many.
    @concurrent
    public func createPlaylist(title: String, videoIds: [String]) async throws -> String {
        let first = Array(videoIds.prefix(Self.perRequest))
        let created = try await edit("playlist/create", ["title": title, "privacyStatus": "PRIVATE", "videoIds": first])
        guard let id = created["playlistId"].string, !id.isEmpty else {
            throw YTMError(.parse, "YouTube didn't return the new playlist.")
        }
        try await addToPlaylist(id, videoIds: Array(videoIds.dropFirst(first.count)))
        return id
    }

    /// Adds an album or playlist to the account's library, or takes it out,
    /// by its playlist ID, as the website's Save button does.
    @concurrent
    public func setSaved(_ saved: Bool, playlistId: String) async throws {
        _ = try await edit(saved ? "like/like" : "like/removelike", ["target": ["playlistId": playlistId]])
    }

    /// Runs the actions on a playlist a hundred at a time. A refused edit,
    /// such as one to a full playlist, still answers 200, so each reply's
    /// status is checked.
    private func editPlaylist(_ playlistId: String, actions: [[String: String]]) async throws {
        for start in stride(from: 0, to: actions.count, by: Self.perRequest) {
            let chunk = Array(actions[start..<min(start + Self.perRequest, actions.count)])
            let reply = try await edit("browse/edit_playlist", ["playlistId": playlistId, "actions": chunk])
            guard Self.succeeded(reply) else {
                throw YTMError(.refused, "YouTube didn't change the playlist.")
            }
        }
    }

    static func succeeded(_ reply: JSON) -> Bool {
        reply["status"].string == "STATUS_SUCCEEDED"
    }

    /// A call as the signed-in account, which every change needs.
    private func edit(_ endpoint: String, _ body: [String: Any]) async throws -> JSON {
        guard await auth.isSignedIn else {
            throw YTMError(.notSignedIn, "Sign in to change your library.")
        }
        return try await innerTube.post(endpoint, body: body)
    }
}

extension Rating {
    /// The like button's state in a `next` response.
    init(next: JSON) {
        let status = next["playerOverlays", "playerOverlayRenderer", "actions"][0]["likeButtonRenderer", "likeStatus"].string
        self = status.flatMap(Rating.init(rawValue:)) ?? .none
    }
}

extension PlaylistOption {
    /// The playlists of a `get_add_to_playlist` reply, or nil when it holds
    /// no list.
    static func list(in reply: JSON) -> [PlaylistOption]? {
        let playlists = reply["contents"][0]["addToPlaylistRenderer", "playlists"]
        guard playlists.isArray else { return nil }
        return playlists.array.compactMap { item in
            let option = item["playlistAddToOptionRenderer"]
            guard let id = option["playlistId"].string, let title = option["title"].text else { return nil }
            return PlaylistOption(
                id: id,
                title: title,
                thumbnail: Thumbnail.pick(option["thumbnail", "thumbnails"], edge: Thumbnail.row),
                contains: option["containsSelectedVideos"].string == "ALL"
            )
        }
    }
}
