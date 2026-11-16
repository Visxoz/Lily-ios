import Foundation
import YTMCore

public enum DownloadState: Equatable, Sendable {
    case none
    /// Waiting its turn, or for a network downloads may use.
    case waiting
    case downloading(Double)
    case downloaded
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

    var key: String { "\(track.id)-\(stream.itag)" }
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
