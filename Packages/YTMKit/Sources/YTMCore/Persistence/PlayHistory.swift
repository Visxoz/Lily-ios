import Foundation

/// The songs played on this phone, newest first, one entry per song.
public struct PlayHistory: Codable, Sendable {
    static let limit = 500

    public private(set) var tracks: [Track]

    /// Keeps the newest play of each song, up to the limit.
    public init(tracks: [Track] = []) {
        var seen = Set<String>()
        self.tracks = []
        for track in tracks where seen.insert(track.id).inserted {
            self.tracks.append(track)
            if self.tracks.count == Self.limit { break }
        }
    }

    /// Cleaned as `init(tracks:)` cleans, so a hand-edited file can't bring in repeats.
    public init(from decoder: any Decoder) throws {
        let file = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tracks: try file.decode([Track].self, forKey: .tracks))
    }

    public mutating func record(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        if tracks.count > Self.limit { tracks.removeLast(tracks.count - Self.limit) }
    }
}
