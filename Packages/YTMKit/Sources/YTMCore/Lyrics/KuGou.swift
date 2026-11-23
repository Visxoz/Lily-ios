import Foundation

/// KuGou's lyrics, timed word by word, which fill in many Chinese and Japanese songs Apple Music lacks.
enum KuGou {
    static let source = "Source: KuGou"

    /// Three requests to China, one after another.
    static func lyrics(for track: Track) async throws -> Lyrics? {
        guard let artist = LyricsMatch.artist(track), let duration = track.duration,
              let songs = try await LyricsSite.get(
                  "mobileservice.kugou.com", "/api/v3/search/song",
                  ["format": "json", "keyword": "\(LyricsMatch.title(track.title)) \(artist)", "page": "1", "pagesize": "20", "showtype": "1"]
              ),
              let hash = hash(in: songs, for: track),
              // The hash names the recording; a search by name alone often finds another version's lyrics.
              let found = try await LyricsSite.get(
                  "krcs.kugou.com", "/search", ["ver": "1", "man": "yes", "client": "mobi", "keyword": "", "duration": String(duration * 1000), "hash": hash]
              ),
              let pick = candidate(in: found, for: track),
              let file = try await LyricsSite.get(
                  "krcs.kugou.com", "/download",
                  ["ver": "1", "client": "pc", "id": pick.id, "accesskey": pick.key, "fmt": "krc", "charset": "utf8"]
              ),
              let content = try? JSON(data: file)["content"].string, let text = Tencent.krcText(content)
        else { return nil }
        return Tencent.krc(text, source: source)
    }

    /// The hash of the nearest-length result that is the track's own recording.
    static func hash(in results: Data, for track: Track) -> String? {
        guard let json = try? JSON(data: results), let length = track.duration else { return nil }
        return json["data", "info"].array.lazy
            .compactMap { song -> (hash: String, gap: Double)? in
                guard let title = song["songname"].string, let artist = song["singername"].string,
                      let duration = song["duration"].double, let hash = song["hash"].string, !hash.isEmpty, hash.allSatisfy(\.isHexDigit),
                      LyricsMatch.sameSong(track, title: title, artist: artist, duration: duration)
                else { return nil }
                return (hash, abs(duration - Double(length)))
            }
            .min { $0.gap < $1.gap }?.hash
    }

    /// The first set of lyrics filed under the track's song, as the hash also brings up uploads of others.
    static func candidate(in results: Data, for track: Track) -> (id: String, key: String)? {
        guard let json = try? JSON(data: results) else { return nil }
        for candidate in json["candidates"].array {
            guard let id = candidate["id"].string ?? candidate["id"].int.map(String.init), let key = candidate["accesskey"].string,
                  let title = candidate["song"].string, let artist = candidate["singer"].string,
                  let ms = candidate["duration"].double,
                  LyricsMatch.sameSong(track, title: title, artist: artist, duration: ms / 1000)
            else { continue }
            return (id, key)
        }
        return nil
    }
}
