import Foundation

/// Apple Music's lyrics, often word by word, as lrc.red keeps them by ISRC.
enum LrcRed {
    static func lyrics(for track: Track) async throws -> Lyrics? {
        guard let artist = LyricsMatch.artist(track), let duration = track.duration,
            let results = try await LyricsSite.get(
            "lrc.red", "/api/v1",
            // No album: lrc.red takes it as a filter, and YouTube's often names another edition.
            ["track": LyricsMatch.title(track.title), "artist": artist, "duration": String(duration)]
        ), let isrc = Self.isrc(in: results, for: track), let ttml = try await LyricsSite.get("lrc.red", "/s/\(isrc).ttml")
        else { return nil }
        return TTML.lyrics(ttml, source: "Source: lrc.red")
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
