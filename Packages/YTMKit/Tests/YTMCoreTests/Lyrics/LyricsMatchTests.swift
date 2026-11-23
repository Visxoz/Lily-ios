import Foundation
import Testing
@testable import YTMCore

@Suite struct LyricsMatchTests {
    private func track(_ title: String, _ artists: String..., duration: Int? = 200) -> Track {
        Track(id: "v", title: title, artists: artists.map { ArtistRef(id: nil, name: $0) }, duration: duration)
    }

    private let lucky = Track(
        id: "v", title: "Get Lucky (feat. Pharrell Williams and Nile Rodgers)",
        artists: [ArtistRef(id: nil, name: "Daft Punk")], duration: 369
    )

    @Test func titlesLoseCreditsAndLabels() {
        #expect(LyricsMatch.title("Get Lucky (feat. Pharrell Williams and Nile Rodgers)") == "Get Lucky")
        #expect(LyricsMatch.title("Song [ft. Someone]") == "Song")
        #expect(LyricsMatch.title("Song (with Someone)") == "Song")
        #expect(LyricsMatch.title("Song feat. Someone & Another") == "Song")
        #expect(LyricsMatch.title("Song (Official Music Video)") == "Song")
        #expect(LyricsMatch.title("Song [Lyrics] (Audio)") == "Song")
        #expect(LyricsMatch.title("Song (Official Visualiser) -") == "Song")
    }

    @Test func titlesKeepTheirVersion() {
        #expect(LyricsMatch.title("Song (Live) [feat. Someone]") == "Song (Live)")
        #expect(LyricsMatch.title("Song feat. Someone (Live)") == "Song (Live)")
        #expect(LyricsMatch.title("Song (Remix feat. Someone)") == "Song (Remix feat. Someone)")
        #expect(LyricsMatch.title("Ft. Lauderdale") == "Ft. Lauderdale")
        #expect(LyricsMatch.title("Song (Sped Up)") == "Song (Sped Up)")
        #expect(LyricsMatch.title("Song (Without You)") == "Song (Without You)")
        #expect(LyricsMatch.title("(Official Video)") == "(Official Video)", "nothing would be left")
    }

    @Test func artistIsTheFirstWithoutTopic() {
        #expect(LyricsMatch.artist(track("Song", "Daft Punk - Topic", "Someone")) == "Daft Punk")
        #expect(LyricsMatch.artist(track("Song")) == nil)
    }

    @Test func sameSongDespiteCreditsAndScript() {
        #expect(LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Daft Punk", duration: 369.4))
        #expect(LyricsMatch.sameSong(track("アイドル", "YOASOBI", duration: 213), title: "アイドル", artist: "YOASOBI", duration: 213.2))
        #expect(LyricsMatch.sameSong(track("Song - 2011 Remaster", "Band"), title: "Song", artist: "Band", duration: 200))
        #expect(LyricsMatch.sameSong(track("Song (Remix)", "Band"), title: "Song [Remix]", artist: "band", duration: 200))
        #expect(LyricsMatch.sameSong(track("Rosé", "ROSÉ"), title: "ROSE", artist: "Rose", duration: 200))
        #expect(LyricsMatch.sameSong(track("晴天", "周杰倫"), title: "晴天", artist: "周杰伦", duration: 200), "Traditional and Simplified")
    }

    @Test func anotherVersionIsAnotherSong() {
        #expect(!LyricsMatch.sameSong(lucky, title: "Get Lucky (Drumless Edition)", artist: "Daft Punk", duration: 369))
        #expect(!LyricsMatch.sameSong(track("Dynamite", "BTS"), title: "Dynamite (Live)", artist: "BTS", duration: 200))
        #expect(!LyricsMatch.sameSong(track("Song (Remix)", "Band"), title: "Song", artist: "Band", duration: 200))
        #expect(!LyricsMatch.sameSong(track("アイドル", "YOASOBI", duration: 213), title: "Idol", artist: "YOASOBI", duration: 213))
        #expect(!LyricsMatch.sameSong(track("✨", "Band"), title: "🪐", artist: "Band", duration: 200), "symbols alone are still the name")
        #expect(LyricsMatch.sameSong(track("✨ ", "Band"), title: "✨", artist: "Band", duration: 200))
        #expect(!LyricsMatch.sameSong(track("✨ (Live)", "Band"), title: "🪐 (Live)", artist: "Band", duration: 200))
        #expect(LyricsMatch.sameSong(track("✨ (feat. IU)", "Band"), title: "✨", artist: "Band", duration: 200))
    }

    @Test func artistsMustShareOne() {
        #expect(LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Pharrell Williams & Daft Punk", duration: 369))
        #expect(LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Someone x Daft Punk feat. Another", duration: 369))
        #expect(LyricsMatch.sameSong(track("Song", "Band - Topic"), title: "Song", artist: "Band", duration: 200))
        #expect(LyricsMatch.sameSong(track("Song", "Band"), title: "Song", artist: "Someone、Band", duration: 200))
        #expect(LyricsMatch.sameSong(track("Dynamite", "BTS"), title: "Dynamite", artist: "BTS (防弹少年团)", duration: 200))
        #expect(!LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Someone Else", duration: 369))
    }

    @Test func lengthsMustBeKnownAndClose() {
        #expect(LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Daft Punk", duration: 372))
        #expect(!LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Daft Punk", duration: 373))
        #expect(!LyricsMatch.sameSong(lucky, title: "Get Lucky", artist: "Daft Punk", duration: nil))
        #expect(!LyricsMatch.sameSong(track("Song", "Band", duration: nil), title: "Song", artist: "Band", duration: 200))
    }

    // MARK: - Agreeing

    private let lines = ["Alpha beta gamma delta", "epsilon zeta eta theta", "iota kappa lambda mu", "nu xi omicron pi"]
    private let starts: [Double] = [10, 14, 18, 22]

    @Test func sameWordsInTimeAgree() {
        let reference = Lyrics(lines: lines, starts: starts)
        #expect(LyricsMatch.agrees(reference, reference))
        #expect(LyricsMatch.agrees(reference, Lyrics(lines: lines, starts: starts.map { $0 + 0.5 })))
        #expect(LyricsMatch.agrees(Lyrics(lines: lines), reference), "untimed words are compared alone")
    }

    @Test func otherWordsOrTimingDisagree() {
        let reference = Lyrics(lines: lines, starts: starts)
        let other = ["one two three four", "five six seven eight", "nine ten eleven twelve", "thirteen fourteen fifteen sixteen"]
        #expect(!LyricsMatch.agrees(reference, Lyrics(lines: other, starts: starts)))
        #expect(!LyricsMatch.agrees(reference, Lyrics(lines: lines, starts: starts.map { $0 + 3 })))
        #expect(!LyricsMatch.agrees(Lyrics(lines: ["", "..."]), reference), "a reference without words agrees with nothing")
    }

    @Test func linesSplitDifferentlyStillAgree() {
        let candidate = Lyrics(
            lines: ["ALPHA, beta", "gamma delta!", "Epsilon zeta eta theta", "(iota) kappa lambda mu", "nu xi omicron pi"],
            starts: [10.2, 12, 14.2, 18.2, 22.2]
        )
        #expect(LyricsMatch.agrees(Lyrics(lines: lines, starts: starts), candidate))
    }

    @Test func eachCJKCharacterIsAWord() {
        let reference = Lyrics(lines: ["あいうえお かきくけこ", "さしすせそ"], starts: [5, 9])
        #expect(LyricsMatch.agrees(reference, Lyrics(lines: ["あいう", "えおかきくけこさしすせそ"], starts: [5.1, 7])))
        #expect(!LyricsMatch.agrees(reference, Lyrics(lines: ["たちつてと なにぬねの", "はひふへほ"], starts: [5, 9])))
        // Only 我 and 你 are written alike in both scripts, so these agree only through the fold.
        #expect(LyricsMatch.agrees(Lyrics(lines: ["我們說愛你", "聽見風聲"]), Lyrics(lines: ["我们说爱你", "听见风声"])))
    }

    // MARK: - lrc.red

    private func results(_ items: String...) -> Data {
        Data(#"{"results":[\#(items.joined(separator: ","))],"source":"HIT-LRC-RED","total":\#(items.count)}"#.utf8)
    }

    private func result(_ title: String, duration: Int, isrc: String, timing: String = "word") -> String {
        #"""
        {"album_name":"Album","artist_name":"BTS","duration":\#(duration),"id":1,"isrc":"\#(isrc)",
         "lyricsUrl":"https://example.com/elsewhere.ttml","timing_type":"\#(timing)","track_name":"\#(title)"}
        """#
    }

    @Test func takesTheFirstResultOfTheSameRecording() {
        let data = results(
            result("Dynamite (Live)", duration: 199, isrc: "KRAAA2000001"),
            result("Dynamite", duration: 230, isrc: "KRAAA2000002"),
            result("Dynamite", duration: 199, isrc: "KRAAA2000009", timing: "none"),
            result("Dynamite", duration: 199, isrc: "kraaa2000003"),
            result("Dynamite", duration: 199, isrc: "KRAAA2000004")
        )
        #expect(LrcRed.isrc(in: data, for: track("Dynamite", "BTS", duration: 199)) == "KRAAA2000003")
    }

    @Test func refusesAnISRCUnfitForThePath() {
        let dynamite = track("Dynamite", "BTS", duration: 199)
        #expect(LrcRed.isrc(in: results(result("Dynamite", duration: 199, isrc: "../KRAAA20000")), for: dynamite) == nil)
        #expect(LrcRed.isrc(in: results(result("Dynamite", duration: 199, isrc: "KRAAA200000")), for: dynamite) == nil)
    }

    @Test func aMissIsNone() async throws {
        #expect(LrcRed.isrc(in: results(), for: track("Dynamite", "BTS")) == nil)
        #expect(LrcRed.isrc(in: Data("<html>".utf8), for: track("Dynamite", "BTS")) == nil)
        #expect(try await LrcRed.lyrics(for: track("Song", duration: 200)) == nil, "no artist, so not asked")
        #expect(try await LrcRed.lyrics(for: track("Song", "Band", duration: nil)) == nil, "no length, so not asked")
    }
}
