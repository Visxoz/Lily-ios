import Foundation
import Testing
@testable import YTMCore

@Suite struct LRCTests {
    @Test func readsEveryStampOfALine() throws {
        let lyrics = try #require(LRC.lyrics("[00:01.50]One\n[00:03.00] [00:05.250]Chorus\n[00:04.00][Two]", source: "S"))
        #expect(lyrics == Lyrics(lines: ["One", "Chorus", "[Two]", "Chorus"], starts: [1.5, 3, 4, 5.25], source: "S"))
    }

    @Test func skipsMetadataAndHonoursTheOffset() {
        let text = "[ar:Someone]\r\n[ti:Something]\r\n[length:03:19.13]\r\n[offset:+500]\r\n[00:02.00]One\r\n[01:00.00]Two\r\n"
        #expect(LRC.lyrics(text, source: "") == Lyrics(lines: ["One", "Two"], starts: [1.5, 59.5]))
        #expect(LRC.lyrics("\u{FEFF}[00:01.00]One", source: "")?.lines == ["One"], "a byte order mark")
    }

    @Test func dropsWordStamps() {
        let lyrics = LRC.lyrics("[00:01.00]<00:01.00>Alpha <00:01.40>beta<00:02.00>\n[00:02.00] <00:02.00> Gamma <00:02.50> delta\n[00:03.00]a <3 b", source: "")
        #expect(lyrics?.lines == ["Alpha beta", "Gamma delta", "a <3 b"])
        #expect(lyrics?.words.isEmpty == true)
    }

    @Test func sortsByStartKeepingTheFilesOrder() {
        let lyrics = LRC.lyrics("[00:05.00]Late\n[00:01.00]Early\n[00:05.00]Also late", source: "")
        #expect(lyrics == Lyrics(lines: ["Early", "Late", "Also late"], starts: [1, 5, 5]))
    }

    @Test func aBareStampIsAPause() {
        let lyrics = LRC.lyrics("[00:01.00]One\n[00:04.00]\n[00:09.00]  \n", source: "")
        #expect(lyrics?.lines == ["One", "♪", "♪"])
    }

    @Test func unstampedTextIsNone() {
        #expect(LRC.lyrics("", source: "") == nil)
        #expect(LRC.lyrics("[ar:Someone]\nplain words\n[0:xx]not a stamp", source: "") == nil)
    }
}

@Suite struct LRCLIBTests {
    private let track = Track(id: "dummyVideo1", title: "Dummy Song", artists: [ArtistRef(id: nil, name: "Dummy Artist")], duration: 200)

    private func answer(_ lyrics: String) -> Data {
        Data(#"""
            {"id":390,"trackName":"Dummy Song","artistName":"Dummy Artist","albumName":"Dummy Album","duration":200.0,\#(lyrics),"hasWordSync":false,"lyricsfile":null}
            """#.utf8)
    }

    @Test func prefersSyncedLyrics() {
        let data = answer(#""instrumental":false,"plainLyrics":"Alpha\nBeta","syncedLyrics":"[00:13.13]Alpha\n[00:16.56]\n[00:27.16]Beta""#)
        let expected = Lyrics(lines: ["Alpha", "♪", "Beta"], starts: [13.13, 16.56, 27.16], source: "Source: LRCLIB")
        #expect(LRCLIB.lyrics(data, for: track) == expected)
    }

    @Test func fallsBackToPlainLyrics() {
        let data = answer(#""instrumental":false,"plainLyrics":"Alpha\n\nBeta\n","syncedLyrics":null"#)
        #expect(LRCLIB.lyrics(data, for: track) == Lyrics(lines: ["Alpha", "", "Beta"], source: "Source: LRCLIB"))
    }

    @Test func anInstrumentalIsNone() {
        #expect(LRCLIB.lyrics(answer(#""instrumental":true,"plainLyrics":null,"syncedLyrics":null"#), for: track) == nil)
        #expect(LRCLIB.lyrics(answer(#""instrumental":true,"plainLyrics":"","syncedLyrics":"[00:00.00]""#), for: track) == nil)
    }

    @Test func anotherSongIsNone() {
        var other = track
        other.title = "Another Tune Entirely"
        #expect(LRCLIB.lyrics(answer(#""instrumental":false,"plainLyrics":"Alpha","syncedLyrics":"[00:01.00]Alpha""#), for: other) == nil)
        #expect(LRCLIB.lyrics(Data("<html></html>".utf8), for: track) == nil, "not JSON")
    }

    @Test func searchesForTheFirstTimedRecordOfTheSong() {
        let records = Data(#"""
            [{"trackName":"Dummy Song","artistName":"Dummy Artist","duration":198.4,"instrumental":false,"plainLyrics":"Plain","syncedLyrics":null},
             {"trackName":"Dummy Song","artistName":"Dummy Artist","duration":230,"instrumental":false,"plainLyrics":"Far","syncedLyrics":"[00:01.00]Far"},
             {"trackName":"Dummy Song","artistName":"Dummy Artist","duration":201.6,"instrumental":false,"plainLyrics":"Timed","syncedLyrics":"[00:01.00]Timed"}]
            """#.utf8)
        #expect(LRCLIB.lyrics(searched: records, for: track) == Lyrics(lines: ["Timed"], starts: [1], source: "Source: LRCLIB"))
        #expect(LRCLIB.lyrics(searched: Data("[]".utf8), for: track) == nil)
    }
}
