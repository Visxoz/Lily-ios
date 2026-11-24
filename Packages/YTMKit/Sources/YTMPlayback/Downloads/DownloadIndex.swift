import Foundation
import Observation
import YTMCore

public enum DownloadState: Equatable, Sendable {
    case none
    /// Waiting its turn, or for a network downloads may use.
    case waiting
    case downloading(Double)
    case downloaded
}

/// From 0 to 1. Each song downloading has its own, so a step redraws only the views showing that song.
@MainActor @Observable final class DownloadProgress {
    var fraction: Double = 0
}

/// An album's or playlist's songs that are done, kept until the index or failed songs change.
struct CollectionTally {
    var ids: Set<String>
    var done: Int
    var count: Int
}

/// What the Downloads page shows beyond the index and failed songs.
struct PageKey: Equatable {
    var revision: Int
    var canDownload: Bool
    var online: Bool?
}

/// What the phone keeps, saved as `downloads.json`.
struct DownloadIndex: Codable, Sendable {
    /// Downloaded songs by video ID.
    var songs: [String: DownloadedSong] = [:]
    /// Songs downloaded one by one, newest first.
    var singles: [Track] = []
    /// Newest first.
    var collections: [DownloadedCollection] = []
    var smart: [Track] = []
    var collectionsSynced: Date?
    var smartRefreshed: Date?

    /// Each song once, in download order: singles, then collections', then smart picks.
    var wanted: [Track] {
        var seen = Set<String>()
        return (singles + collections.flatMap(\.tracks) + smart).filter { seen.insert($0.id).inserted }
    }
}

struct DownloadedSong: Codable, Sendable {
    var track: Track
    /// Saved without headers. Its URL is rebuilt from `key`, as the app's container moves with updates.
    var stream: ResolvedStream
    var added: Date

    var key: String { Self.key(videoId: track.id, itag: stream.itag) }

    /// The file's name, shared with the play cache so a song played lately is adopted rather than fetched.
    static func key(videoId: String, itag: Int) -> String { "\(videoId)-\(itag)" }
}

/// An album or playlist, kept in step with YouTube's once a day.
struct DownloadedCollection: Codable, Equatable, Sendable {
    var route: Route
    var title: String
    var subtitle: String
    var thumbnail: String?
    var tracks: [Track]

    /// Nil for any other route, which is never downloaded.
    var card: Card? {
        switch route {
        case .album(let id): Card(kind: .album, id: id, title: title, subtitle: subtitle, thumbnail: thumbnail)
        case .playlist(let id): Card(kind: .playlist, id: id, title: title, subtitle: subtitle, thumbnail: thumbnail)
        default: nil
        }
    }
}
