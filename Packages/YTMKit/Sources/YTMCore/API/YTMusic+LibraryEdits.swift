import Foundation

extension YTMusic {
    /// Video IDs YouTube takes in one playlist call.
    private static let perRequest = 100

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

    @concurrent
    public func playlists(adding videoId: String) async throws -> [PlaylistOption] {
        let reply = try await edit("playlist/get_add_to_playlist", ["videoIds": [videoId]])
        guard let options = PlaylistOption.list(in: reply) else {
            throw YTMError(.parse, "YouTube didn't list your playlists.")
        }
        return options
    }

    @concurrent
    public func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws {
        try await editPlaylist(playlistId, actions: videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0] })
    }

    /// The create call takes only so many songs, so the rest are added after.
    @concurrent
    public func createPlaylist(title: String, videoIds: [String]) async throws -> String {
        let first = Array(videoIds.prefix(Self.perRequest))
        let created = try await edit("playlist/create", ["title": title, "privacyStatus": "PRIVATE", "videoIds": first], retries: 0)
        guard let id = created["playlistId"].string, !id.isEmpty else {
            throw YTMError(.parse, "YouTube didn't return the new playlist.")
        }
        try await addToPlaylist(id, videoIds: Array(videoIds.dropFirst(first.count)))
        return id
    }

    /// A refused edit, such as one to a full playlist, still answers 200, so
    /// each reply's status is checked.
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

    /// Creating passes `retries` 0, as a timed-out create YouTube carried out would make a second playlist.
    private func edit(_ endpoint: String, _ body: [String: Any], retries: Int = InnerTube.retries) async throws -> JSON {
        guard await auth.isSignedIn else {
            throw YTMError(.notSignedIn, "Sign in to change your library.")
        }
        return try await innerTube.post(endpoint, body: body, retries: retries)
    }
}

extension Rating {
    init(next: JSON) {
        let status = next["playerOverlays", "playerOverlayRenderer", "actions"][0]["likeButtonRenderer", "likeStatus"].string
        self = status.flatMap(Rating.init(rawValue:)) ?? .none
    }
}

extension PlaylistOption {
    /// Nil when the reply holds no list.
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
