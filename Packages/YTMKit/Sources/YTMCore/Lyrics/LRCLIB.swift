import Foundation

/// LRCLIB's community lyrics, found by name and length, as it knows no video IDs.
enum LRCLIB {
    // shortcut: line timing only; its YAML `lyricsfile` has word timing for many songs, worth reading if lrc.red
    // goes quiet.
    static func lyrics(for track: Track) async throws -> Lyrics? {
        guard let artist = LyricsMatch.artist(track), let duration = track.duration else { return nil }
        let title = LyricsMatch.title(track.title)
        if let data = try await LyricsSite.get(
            "lrclib.net", "/api/get", ["track_name": title, "artist_name": artist, "duration": String(duration)]
        ), let found = lyrics(data, for: track) {
            return found
        }
        // The exact lookup wants the length to the second, which a record a little off misses.
        guard let data = try await LyricsSite.get("lrclib.net", "/api/search", ["track_name": title, "artist_name": artist]) else { return nil }
        return lyrics(searched: data, for: track)
    }

    /// Nil unless the answer is the track's song and has words: LRCLIB gives its nearest record within a
    /// couple of seconds, which can be another song altogether.
    static func lyrics(_ data: Data, for track: Track) -> Lyrics? {
        (try? JSON(data: data)).flatMap { lyrics($0, for: track) }
    }

    /// The first timed record of the track's song in a search's results, else the first untimed one.
    static func lyrics(searched data: Data, for track: Track) -> Lyrics? {
        guard let json = try? JSON(data: data) else { return nil }
        var plain: Lyrics?
        for record in json.array {
            guard let found = lyrics(record, for: track) else { continue }
            if found.isSynced { return found }
            plain = plain ?? found
        }
        return plain
    }

    private static func lyrics(_ json: JSON, for track: Track) -> Lyrics? {
        guard json["instrumental"].bool != true, let title = json["trackName"].string, let artist = json["artistName"].string,
              LyricsMatch.sameSong(track, title: title, artist: artist, duration: json["duration"].double)
        else { return nil }
        return lyrics(synced: json["syncedLyrics"].string, plain: json["plainLyrics"].string)
    }

    /// The timed lyrics, else the text if there is any.
    static func lyrics(synced: String?, plain: String?) -> Lyrics? {
        if let synced, let lyrics = LRC.lyrics(synced, source: source) { return lyrics }
        guard let plain, !plain.allSatisfy(\.isWhitespace) else { return nil }
        return Lyrics(lines: Lyrics.lines(plain), source: source)
    }

    private static let source = "Source: LRCLIB"
}
