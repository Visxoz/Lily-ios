import Foundation

/// LRCLIB's community lyrics, found by name and length, as it knows no video IDs.
enum LRCLIB {
    // shortcut: line timing only, from `/api/get`; read `lyricsfile` for its word timing, and try `/api/search`
    // on a miss, if LRCLIB is to fill more gaps.
    static func lyrics(for track: Track) async throws -> Lyrics? {
        guard let artist = LyricsMatch.artist(track), let duration = track.duration else { return nil }
        guard let data = try await LyricsSite.get(
            "lrclib.net", "/api/get", ["track_name": LyricsMatch.title(track.title), "artist_name": artist, "duration": String(duration)]
        ) else { return nil }
        return lyrics(data, for: track)
    }

    /// Nil unless the answer is the track's song and has words: LRCLIB gives its nearest record within a
    /// couple of seconds, which can be another song altogether.
    static func lyrics(_ data: Data, for track: Track) -> Lyrics? {
        guard let json = try? JSON(data: data), json["instrumental"].bool != true,
              let title = json["trackName"].string, let artist = json["artistName"].string,
              LyricsMatch.sameSong(track, title: title, artist: artist, duration: json["duration"].double)
        else { return nil }
        if let synced = json["syncedLyrics"].string, let lyrics = LRC.lyrics(synced, source: source) { return lyrics }
        guard let plain = json["plainLyrics"].string, !plain.allSatisfy(\.isWhitespace) else { return nil }
        return Lyrics(lines: Lyrics.lines(plain), source: source)
    }

    private static let source = "Source: LRCLIB"
}
