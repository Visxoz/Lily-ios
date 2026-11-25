import Foundation
@testable import YTMCore

/// Word-timed lyrics from lrc.red or KuGou where they agree with YouTube's, else timed lines or text.
enum LyricsChecks {
    static func run(_ report: Report) async {
        await report.check("lyrics") { findings in
            var synced = 0
            var wordSynced = 0
            for song in Live.songs {
                guard let lyrics = try await Live.api.lyrics(for: song.track) else {
                    findings.fail("\(song.title): no lyrics")
                    continue
                }
                findings.expect(lyrics.lines.count >= 10, "\(song.title): \(lyrics.lines.count) lines")
                findings.expect(!lyrics.source.isEmpty, "\(song.title): no source")
                if lyrics.isWordSynced {
                    wordSynced += 1
                    findings.expect(lyrics.words.joined().allSatisfy { $0.start <= $0.end }, "\(song.title): a word ends before it starts")
                }
                if lyrics.isSynced {
                    synced += 1
                    findings.expect(zip(lyrics.starts, lyrics.starts.dropFirst()).allSatisfy { $0 <= $1 }, "\(song.title): timings out of order")
                    findings.expect(lyrics.starts.last.map { $0 < Double(song.seconds) } ?? false, "\(song.title): a line after the song ends")
                    let middle = lyrics.lines.count / 2
                    findings.expect(lyrics.lineIndex(at: lyrics.starts[middle] + 0.01) == middle, "\(song.title): the line playing isn't found")
                }
                let first = lyrics.lines.first { !$0.isEmpty } ?? ""
                findings.note("\(song.title): \(lyrics.lines.count) lines, \(timing(lyrics)), \(lyrics.source); \"\(first.prefix(40))\"")
            }
            findings.expect(synced > 0, "no song had timed lyrics")
            // lrc.red is one person's site, so its going quiet should show here rather than on the phone.
            findings.expect(wordSynced > 0, "no song had word-timed lyrics")
            let community = try await LRCLIB.lyrics(for: Live.songs[1].track)
            findings.expect(community?.isSynced == true, "LRCLIB: no timed lines for \(Live.songs[1].title)")
            try await versions(&findings)
            try await chinese(&findings)
            try await translated(&findings)
            try await sites(&findings)
        }
    }

    /// NewJeans' Super Shy as a home tile gives it, without its length, which lrc.red needs for its translation.
    private static func translated(_ findings: inout Findings) async throws {
        let tile = Track(id: "0c7zGU2C2mM", title: "Super Shy", artists: [ArtistRef(id: nil, name: "NewJeans")])
        let lyrics = try await Live.api.lyrics(for: tile)
        findings.expect(lyrics?.hasTranslations == true, "Super Shy: no translation, from \(lyrics?.source ?? "nowhere")")
    }

    /// Each site alone for a random song, as the lyrics above stop at the first good answer. The hub needs the app's
    /// Cloudflare pass, so isn't asked.
    private static func sites(_ findings: inout Findings) async throws {
        guard let song = Live.songs.randomElement() else { return }
        let track = song.track
        async let lrcRed = outcome { try await LrcRed.lyrics(for: track) }
        async let kugou = outcome { try await KuGou.lyrics(for: track) }
        async let lrclib = outcome { try await LRCLIB.lyrics(for: track) }
        var video = track
        video.isVideo = true
        guard let own = try await Live.api.lyrics(for: video) else { return findings.fail("\(song.title): no YouTube lyrics") }
        for (site, answer) in [("lrc.red", await lrcRed), ("KuGou", await kugou), ("LRCLIB", await lrclib)] {
            switch answer {
            case .failure(let error):
                findings.fail("\(site): \(error)")
            case .success(nil):
                findings.fail("\(site): nothing for \(song.title)")
            case .success(let lyrics?):
                findings.expect(LyricsMatch.agrees(own, lyrics), "\(site): \(song.title) taken as another version")
                findings.note("\(site) alone: \(song.title), \(lyrics.lines.count) lines, \(timing(lyrics))")
            }
        }
    }

    /// A site's failure as its answer, so one failing doesn't hide the others'.
    private static func outcome(_ fetch: () async throws -> Lyrics?) async -> Result<Lyrics?, any Error> {
        do { return .success(try await fetch()) } catch { return .failure(error) }
    }

    private static func timing(_ lyrics: Lyrics) -> String {
        lyrics.isWordSynced ? "word-synced" : lyrics.isSynced ? "synced" : "plain"
    }

    /// YouTube writes 周杰倫's 晴天 in Traditional characters and the other sites file it in Simplified ones, so
    /// lrc.red finds it only on a second search, and KuGou's must agree with YouTube's words across the scripts.
    private static func chinese(_ findings: inout Findings) async throws {
        var song = Track(id: "SJKoWAd5ySo", title: "晴天", artists: [ArtistRef(id: nil, name: "周杰倫")], duration: 270)
        let lyrics = try await Live.api.lyrics(for: song)
        findings.expect(lyrics?.isWordSynced == true, "晴天: not word-synced, from \(lyrics?.source ?? "nowhere")")
        findings.note("晴天: \(lyrics?.lines.count ?? 0) lines, \(lyrics?.source ?? "none")")
        let kugou = await LyricsSite.within(.seconds(4)) { [song] in try await KuGou.lyrics(for: song) }
        guard let kugou, kugou.isWordSynced else { return findings.fail("KuGou: no word timing for 晴天") }
        // A music video is given YouTube's lyrics alone.
        song.isVideo = true
        guard let own = try await Live.api.lyrics(for: song) else { return findings.fail("晴天: no YouTube lyrics") }
        findings.expect(LyricsMatch.agrees(own, kugou), "KuGou's 晴天 taken as another version")
    }

    /// YOASOBI's アイドル and its English version share a name, artist and length, so only YouTube's own
    /// lyrics tell lrc.red's two apart.
    private static func versions(_ findings: inout Findings) async throws {
        let song = Track(id: "m9SMT5ipbxk", title: "アイドル", artists: [ArtistRef(id: nil, name: "YOASOBI")], duration: 213, isVideo: true)
        guard let own = try await Live.api.lyrics(for: song) else { return findings.fail("アイドル: no YouTube lyrics") }
        for (isrc, same) in [("JPP302300157", true), ("JPP302300335", false)] {
            guard let data = try await LyricsSite.get("lrc.red", "/s/\(isrc).ttml"), let apple = TTML.lyrics(data, source: "") else {
                findings.fail("lrc.red: no \(isrc)")
                continue
            }
            findings.expect(LyricsMatch.agrees(own, apple) == same, "\(isrc) taken as \(same ? "another" : "the same") version")
        }
    }
}
