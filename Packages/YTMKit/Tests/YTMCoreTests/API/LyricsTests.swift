import Foundation
import Testing
@testable import YTMCore

@Suite struct LyricsTests {
    private func timed(_ lines: String) throws -> JSON {
        try JSON(data: Data(#"""
            {"contents":{"elementRenderer":{"newElement":{"type":{"componentType":{"model":{"timedLyricsModel":{"lyricsData":{
              "timedLyricsData":[\#(lines)],"sourceMessage":"Source: Musixmatch"}}}}}}}},"frameworkUpdates":{"big":[1,2,3]}}
            """#.utf8))
    }

    @Test func choosesOtherSitesOnlyWhereTheyAgreeWithYouTube() {
        let words = [[Lyrics.Word(text: "Alpha", start: 1, end: 2)], [Lyrics.Word(text: "Beta", start: 3, end: 4)]]
        let youtube = Lyrics(lines: ["Alpha", "Beta"], starts: [1, 3])
        let plain = Lyrics(lines: ["Alpha", "Beta"])
        let apple = Lyrics(lines: ["Alpha", "Beta"], starts: [1, 3], words: words, source: "Source: lrc.red")
        let late = Lyrics(lines: ["Alpha", "Beta"], starts: [5, 7], words: words, source: "Source: lrc.red")
        let other = Lyrics(lines: ["Gamma", "Delta"], starts: [1, 3], source: "Source: LRCLIB")
        let community = Lyrics(lines: ["Alpha", "Beta"], starts: [1.2, 3.2], source: "Source: LRCLIB")
        let lines = Lyrics(lines: ["Alpha", "Beta"], starts: [1.1, 3.1], source: "Source: lrc.red")
        let kugou = Lyrics(lines: ["Alpha", "Beta"], starts: [1.3, 3.3], words: words, source: "Source: KuGou")
        func chosen(_ own: Lyrics?, apple: Lyrics? = nil, kugou: Lyrics? = nil, community: Lyrics? = nil) -> Lyrics? {
            Lyrics.chosen(
                youtube: own, apple: [apple].compactMap { .checked($0, against: own) },
                others: [kugou, community].compactMap { .checked($0, against: own) }
            )
        }
        #expect(chosen(youtube, apple: apple, kugou: kugou) == apple)
        #expect(chosen(youtube, apple: late) == youtube, "out of time with the recording")
        #expect(chosen(youtube, apple: plain) == youtube, "untimed never beats timed")
        #expect(chosen(youtube, apple: lines, kugou: kugou) == kugou, "words beat lines")
        #expect(chosen(youtube, apple: lines) == lines)
        #expect(chosen(plain, kugou: kugou) == kugou, "timing YouTube's words lack")
        #expect(chosen(plain, kugou: other) == plain, "another song's")
        #expect(chosen(nil, apple: apple, community: community) == apple)
        #expect(chosen(plain, community: community) == community)
        #expect(chosen(plain, community: other) == plain, "another song's")
        #expect(chosen(plain, community: plain) == plain, "untimed adds nothing to YouTube's")
        #expect(chosen(nil, community: plain) == plain, "better than none")
        #expect(chosen(nil) == nil)
    }

    private func timedLines(_ lines: [String], _ starts: [Double], ends: [Double] = [], words: [[Lyrics.Word]] = []) -> Lyrics {
        Lyrics(lines: lines, starts: starts, ends: ends, words: words)
    }

    private func words(_ spans: [(Double, Double)]) -> [Lyrics.Word] {
        spans.map { Lyrics.Word(text: "la ", start: $0.0, end: $0.1) }
    }

    @Test func sungByWordsJoinsThoseABreathApart() {
        let lyrics = timedLines(
            ["One", "Two", "Three"], [1, 5, 20],
            // Out of order, overlapping, and one ending before it starts; a line without words is sung as a line.
            words: [words([(1, 1.5), (1.9, 2.4), (3.1, 3.5)]), words([(6, 7), (5, 6.5), (9, 8)]), []]
        )
        #expect(lyrics.sung == [1..<2.4, 3.1..<3.5, 5..<7, 20..<25])
    }

    @Test func sungByLinesRunsToTheNextAtMostAWhile() {
        #expect(timedLines(["One", "♪", "Two", "Three"], [0, 10, 12, 13]).sung == [0..<5, 12..<18])
    }

    @Test func sungByLinesEndsWhereTheyEnd() {
        // Shorter than the cap, longer, past the next line, and not after its start.
        let lyrics = timedLines(["One", "♪", "Two", "Three", "♪", "Four"], [0, 10, 12, 22, 25, 35], ends: [3, 11, 20, 40, 31, 34])
        #expect(lyrics.sung == [0..<3, 12..<17, 22..<25, 35..<40])
    }

    @Test func sungIsUnknownWithoutTiming() {
        #expect(Lyrics(lines: ["One", "Two"]).sung == nil)
        #expect(Lyrics(lines: []).sung == nil)
        #expect(timedLines(["", "♪"], [0, 4]).sung == nil)
    }

    @Test func readsSyncedLinesWithTheirStarts() throws {
        let json = try timed(#"""
            {"lyricLine":"One","cueRange":{"startTimeMilliseconds":"1500","endTimeMilliseconds":"3000","metadata":{"id":"1"}}},
            {"lyricLine":"Two","cueRange":{"startTimeMilliseconds":"3000","endTimeMilliseconds":"4000"}}
            """#)
        #expect(Lyrics(timed: json) == Lyrics(lines: ["One", "Two"], starts: [1.5, 3.0], ends: [3, 4], source: "Source: Musixmatch"))
    }

    @Test func untimedLinesHaveNoStarts() throws {
        let lyrics = try #require(Lyrics(timed: timed(#"{"lyricLine":"One"},{"lyricLine":"Two","cueRange":{"startTimeMilliseconds":"3000"}}"#)))
        #expect(lyrics.lines == ["One", "Two"])
        #expect(lyrics.starts.isEmpty, "synced only when every line is")
        #expect(lyrics.ends.isEmpty)
    }

    @Test func endsAreKeptOnlyWhenEveryLineHasOne() throws {
        let lyrics = try #require(Lyrics(timed: timed(#"""
            {"lyricLine":"One","cueRange":{"startTimeMilliseconds":"1500","endTimeMilliseconds":"3000"}},
            {"lyricLine":"Two","cueRange":{"startTimeMilliseconds":"3000"}}
            """#)))
        #expect(lyrics.starts == [1.5, 3])
        #expect(lyrics.ends.isEmpty)
    }

    @Test func otherShapesAreNone() throws {
        #expect(Lyrics(timed: try timed("")) == nil, "no lines")
        #expect(Lyrics(timed: try JSON(data: Data(#"{"contents":{"sectionListRenderer":{}}}"#.utf8))) == nil)
    }

    @Test func readsPlainLyrics() throws {
        let json = try JSON(data: Data(#"""
            {"contents":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{
              "description":{"runs":[{"text":"One\r\nTwo\n\nThree\n"}]},"footer":{"runs":[{"text":"Source: LyricFind"}]}}}]}}}
            """#.utf8))
        let lyrics = try #require(try Lyrics(plain: json))
        #expect(lyrics == Lyrics(lines: ["One", "Two", "", "Three"], source: "Source: LyricFind"))
        #expect(!lyrics.isSynced)
    }

    @Test func aMessageIsNoLyrics() throws {
        let message = try JSON(data: Data(#"{"contents":{"messageRenderer":{"text":{"runs":[{"text":"Lyrics not available"}]}}}}"#.utf8))
        #expect(try Lyrics(plain: message) == nil)
        #expect(throws: YTMError.self) { try Lyrics(plain: JSON(data: Data(#"{"contents":{"sectionListRenderer":{"contents":[]}}}"#.utf8))) }
    }

    @Test func splitsLinesAsRust() {
        #expect(Lyrics.lines("") == [])
        #expect(Lyrics.lines("a") == ["a"])
        #expect(Lyrics.lines("a\n\n") == ["a", ""])
        #expect(Lyrics.lines("a\r\nb") == ["a", "b"])
    }
}
