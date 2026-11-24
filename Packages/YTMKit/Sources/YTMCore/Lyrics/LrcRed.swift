import Foundation

/// Apple Music's lyrics, often word by word, as lrc.red keeps them by ISRC.
enum LrcRed {
    static let source = "Source: lrc.red"

    static func lyrics(for track: Track) async throws -> Lyrics? {
        guard let artist = LyricsMatch.artist(track) else { return nil }
        let title = LyricsMatch.title(track.title)
        var isrc = try await search(title, artist, for: track)
        // Chinese songs are filed in Simplified characters, under which a search in Traditional ones misses. Kana
        // mark Japanese, whose kanji aren't Chinese to simplify.
        if isrc == nil, !(title + artist).unicodeScalars.contains(where: { (0x3040..<0x3100).contains($0.value) }) {
            let simplified = (LyricsMatch.simplified(title), LyricsMatch.simplified(artist))
            if simplified != (title, artist) { isrc = try await search(simplified.0, simplified.1, for: track) }
        }
        guard let isrc, let ttml = try await LyricsSite.get("lrc.red", "/s/\(isrc).ttml") else { return nil }
        return TTML.lyrics(ttml, source: source)
    }

    /// Whether `lyrics` searches under the names `track` has, with nothing cut or simplified, as the hub is sent them.
    static func searchesAsGiven(_ track: Track) -> Bool {
        let title = LyricsMatch.title(track.title)
        guard let artist = LyricsMatch.artist(track) else { return true }
        return title == track.title && artist == track.artistNames && LyricsMatch.simplified(title + artist) == title + artist
    }

    private static func search(_ title: String, _ artist: String, for track: Track) async throws -> String? {
        guard let duration = track.duration,
              // No album: lrc.red takes it as a filter, and YouTube's often names another edition.
              let results = try await LyricsSite.get("lrc.red", "/api/v1", ["track": title, "artist": artist, "duration": String(duration)])
        else { return nil }
        return isrc(in: results, for: track)
    }

    /// The ISRC of the first timed result that is the track's own recording, since the search returns whatever
    /// is nearest, even another version or length. The path is built from a checked ISRC, not taken from the
    /// answer, so nothing else can enter it.
    static func isrc(in results: Data, for track: Track) -> String? {
        guard let json = try? JSON(data: results) else { return nil }
        for result in json["results"].array {
            guard result["timing_type"].string != "none", let title = result["track_name"].string, let artist = result["artist_name"].string,
                  LyricsMatch.sameSong(track, title: title, artist: artist, duration: result["duration"].double),
                  let isrc = result["isrc"].string?.uppercased(), isrc.wholeMatch(of: #/[A-Z]{2}[A-Z0-9]{3}[0-9]{7}/#) != nil
            else { continue }
            return isrc
        }
        return nil
    }
}
