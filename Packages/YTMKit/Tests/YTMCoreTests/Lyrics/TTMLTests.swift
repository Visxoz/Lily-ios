import Foundation
import Testing
@testable import YTMCore

@Suite struct TTMLTests {
    /// lrc.red's document shape, with dummy words.
    private func lyrics(_ body: String, head: String = "", timing: String = "Word") -> Lyrics? {
        TTML.lyrics(Data(#"""
            <tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" lrc:timing="\#(timing)" xml:lang="en"><head><metadata><ttm:agent type="person" xml:id="v1"/><sourceMetadata xmlns="http://lrc.red/lyric-ttml-internal" leadingSilence="0">\#(head)</sourceMetadata></metadata></head><body dur="1:00.000"><div begin="1.000" end="9.000" lrc:songPart="Verse">
            \#(body)
            </div></body></tt>
            """#.utf8), source: "Source: Apple Music")
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> Lyrics.Word {
        Lyrics.Word(text: text, start: start, end: end)
    }

    @Test func readsWordsWithSyllablesAndTheSpacesBetween() {
        let read = lyrics(#"""
            <p begin="1.200" end="3.000" lrc:key="L1" ttm:agent="v1"><span begin="1.000" end="1.500">Lorem</span> <span begin="1.500" end="1.750">ip</span><span begin="1.750" end="2.000">sum</span> <span begin="2.000" end="2.500">dolor</span>, <span begin="2.500" end="3.000">sit</span></p>
            <p begin="4.000" end="5.000" lrc:key="L2" ttm:agent="v1"><span begin="4.000" end="5.000">Amet</span></p>
            """#)
        let words = [
            [word("Lorem ", 1, 1.5), word("ip", 1.5, 1.75), word("sum ", 1.75, 2), word("dolor, ", 2, 2.5), word("sit", 2.5, 3)],
            [word("Amet", 4, 5)],
        ]
        #expect(read == Lyrics(lines: ["Lorem ipsum dolor, sit", "Amet"], starts: [1, 4], words: words, source: "Source: Apple Music"))
        #expect(read?.isWordSynced == true)
    }

    @Test func readsTheHeadsFirstTranslationAndRomanisationByLine() {
        let head = #"""
            <translations><translation type="replacement" xml:lang="en-US"><text for="L1"><span begin="1.000" end="2.000" xmlns="http://www.w3.org/ns/ttml">Other</span></text><text for="L2">Same</text></translation><translation xml:lang="fr"><text for="L1">Autre</text><text for="L3">Encore</text></translation></translations><transliterations><transliteration xml:lang="ko-Latn"><text for="L1"><span begin="1.000" end="2.000" xmlns="http://www.w3.org/ns/ttml">Roman</span> <span ttm:role="x-bg" xmlns="http://www.w3.org/ns/ttml"><span begin="2.000" end="2.500">(echo)</span></span></text></transliteration></transliterations>
            """#
        let body = #"""
            <p begin="1.000" end="2.000" lrc:key="L1"><span begin="1.000" end="2.000">Lorem</span></p>
            <p begin="3.000" end="4.000" lrc:key="L2">Same</p>
            <p begin="5.000" end="6.000" lrc:key="L3">Ipsum</p>
            """#
        let read = lyrics(body, head: head)
        #expect(read?.lines == ["Lorem", "Same", "Ipsum"])
        #expect(read?.words.first == [word("Lorem", 1, 2)])
        #expect(read?.translations == ["Other", "", ""], "the same line is left out, and the second language unread")
        #expect(read?.romanised == ["Roman (echo)", "", ""])
        let plain = lyrics(body)
        #expect(plain?.translations == [] && plain?.romanised == [])
    }

    @Test func keepsBackgroundVocalsInlineAndTakesTranslatedSpansAside() {
        let head = #"<translations><translation xml:lang="fr"><text for="L1">Tête</text></translation></translations>"#
        let read = lyrics(#"""
            <p begin="1.000" end="2.500" lrc:key="L1"><span begin="1.000" end="1.500">Lorem</span> <span ttm:role="x-bg"><span begin="1.400" end="2.000">(Ip-</span><span begin="2.000" end="2.500">sum)</span></span><span ttm:role="x-translation" xml:lang="fr"><span begin="1.000" end="2.000">Autre</span></span><span ttm:role="x-roman">Roma</span></p>
            """#, head: head)
        #expect(read?.lines == ["Lorem (Ip-sum)"])
        #expect(read?.words == [[word("Lorem ", 1, 1.5), word("(Ip-", 1.4, 2), word("sum)", 2, 2.5)]])
        #expect(read?.translations == ["Autre"], "the line's own over the head's")
        #expect(read?.romanised == ["Roma"])
    }

    @Test func readsLineTimedDocuments() {
        let read = lyrics(
            #"""
            <p begin="1.000" end="2.000">Lorem ipsum</p>
            <p begin="00:00:03.500" end="4.000">
                Dolor,
                sit &amp; amet
            </p>
            """#,
            timing: "Line"
        )
        #expect(read == Lyrics(lines: ["Lorem ipsum", "Dolor, sit & amet"], starts: [1, 3.5], source: "Source: Apple Music"))
        #expect(read?.isSynced == true)
        #expect(lyrics("<p>Lorem</p><p>Ipsum</p>", timing: "None")?.isSynced == false, "unsynced without any times")
    }

    @Test func matchesPrefixedNamesAndKeepsLinesWithoutWords() {
        let read = TTML.lyrics(Data(#"""
            <tt:tt xmlns:tt="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word"><tt:head/><tt:body><tt:div>
              <tt:p begin="1.000" end="2.000"><tt:span begin="1.000" end="1.500">Lorem</tt:span>
                <tt:span begin="1.500" end="2.000">ipsum</tt:span>
              </tt:p>
              <tt:p begin="3.000" end="4.000">Dolor</tt:p>
            </tt:div></tt:body></tt:tt>
            """#.utf8), source: "")
        #expect(read?.lines == ["Lorem ipsum", "Dolor"])
        #expect(read?.words == [[word("Lorem ", 1, 1.5), word("ipsum", 1.5, 2)], []])
        #expect(read?.isWordSynced == true)
    }

    @Test func readsClockValues() {
        #expect(TTML.seconds("27.395") == 27.395)
        #expect(TTML.seconds("1:05.25") == 65.25)
        #expect(TTML.seconds("1:02:03.5") == 3723.5)
        #expect(TTML.seconds("00:00:00.458") == 0.458)
        #expect(TTML.seconds("12.5s") == 12.5)
        #expect(TTML.seconds("500ms") == 0.5)
        #expect(TTML.seconds("") == nil)
        #expect(TTML.seconds("soon") == nil)
        #expect(TTML.seconds("1:02:03:04") == nil)
    }

    @Test func malformedOrEmptyIsNone() {
        #expect(TTML.lyrics(Data(#"<tt><body><p begin="1.000">Lorem</body></tt>"#.utf8), source: "") == nil)
        #expect(TTML.lyrics(Data("{}".utf8), source: "") == nil)
        #expect(lyrics("") == nil)
    }
}
