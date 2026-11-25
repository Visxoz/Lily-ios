import Foundation
import Testing
@testable import YTMCore

@Suite struct TencentTests {
    /// Made-up lyrics, compressed and masked by a script apart from the decoder: a title line and a credit, laid
    /// end to end with one length as KuGou lays them, then two sung lines.
    private let download = """
        a3JjMTjbGsglTQAO96N6RKC8yyswOT8Nch0jMzMnZe1/ekra+ENF48GkItsLVFQtrMmGcdpdebOEKpzfSy7ZNRbzWrLAQ0H1VIh+cdcwQQN8q9I1\
        kWdil/iq9xLV0SaI2olHscA/dxfP0oibhcqNeV6gbfkJAWe/6AiSUzUSGw0XSvoz0k/QpZYmmEVKdSHu0h6nRREMTb9xhFpByDADZcl2fAia9Pgs\
        zr4O/TUTHjrOGZMl7w==
        """

    private let sung = Lyrics(
        lines: ["Alpha beta it's", "晴天"],
        starts: [10, 12],
        words: [
            [.init(text: "Alpha ", start: 10, end: 10.5), .init(text: "beta ", start: 10.5, end: 11), .init(text: "it's", start: 11.25, end: 12)],
            [.init(text: "晴", start: 12, end: 12.5), .init(text: "天", start: 12.5, end: 13)],
        ],
        source: "S"
    )

    @Test func readsKuGousLinesWordByWord() throws {
        let text = try #require(Tencent.krcText(download))
        #expect(Tencent.krc(text, source: "S") == sung)
    }

    @Test func readsQQsLinesWordByWord() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <QrcInfos><LyricInfo LyricCount="1"><Lyric_1 LyricType="1" LyricContent="[ti:Dummy Song]
            [offset:0]
            [0,1500]Dummy Song(0,500) - (500,500)Dummy Artist(1000,500)
            [1500,1500]Words: (1500,700)Some "One"(2200,800)
            [10000,2000]Alpha (10000,500)beta(10500,500) (11000,250)it&apos;s(11250,750)
            [12000,1000]晴(12000,500)天(12500,500)
            "/></LyricInfo></QrcInfos>
            """
        let text = try #require(Tencent.qrcContent(xml))
        #expect(Tencent.qrc(text, source: "S") == sung)
    }

    @Test func honoursTheOffset() {
        let lyrics = Tencent.krc("[offset:500]\n[1000,500]<0,500,0>One", source: "")
        #expect(lyrics == Lyrics(lines: ["One"], starts: [0.5], words: [[.init(text: "One", start: 0.5, end: 1)]]))
    }

    @Test func keepsSungLinesThatLookLikeCredits() {
        let duet = Tencent.krc("[1000,500]<0,500,0>男：<500,500,0>One\n[2000,500]<0,500,0>合：<500,500,0>Two", source: "")
        #expect(duet?.lines == ["男：One", "合：Two"])
        #expect(Tencent.krc("[9000,500]<0,500,0>Now - then", source: "")?.lines == ["Now - then"], "a title-like line sung later")
        #expect(Tencent.qrc("[0,900]Me - you(0,900)\n[950,2000]Sung(950,2000)", source: "")?.lines == ["Sung"], "the title alone")
    }

    @Test func anythingElseIsNone() {
        #expect(Tencent.krcText("not base64") == nil)
        #expect(Tencent.krcText(Data("krc2abcdef".utf8).base64EncodedString()) == nil)
        #expect(Tencent.krcText(Data("krc1abcdef".utf8).base64EncodedString()) == nil, "not a zlib stream once unmasked")
        #expect(Tencent.krc("[ti:Song]\n[0,500]<0,500,0>Song - Band\n[500,500]<0,500,0>Lyrics by: Someone\n[2000,500]", source: "") == nil)
        #expect(Tencent.qrcContent("<QrcInfos/>") == nil)
        #expect(Tencent.krc("[inf,500]<0,500,0>One\n[1000,500]<nan,500,0>Two", source: "") == nil, "times that aren't whole numbers")
    }
}

@Suite struct KuGouTests {
    private let track = Track(id: "dummyVideo1", title: "晴天", artists: [ArtistRef(id: nil, name: "周杰倫")], duration: 270)

    @Test func picksTheNearestRecordingOfTheSong() {
        let results = Data(#"""
            {"data":{"info":[
              {"songname":"晴天 (Live)","singername":"周杰伦","duration":270,"hash":"AAAA0001"},
              {"songname":"晴天","singername":"Someone Else","duration":270,"hash":"AAAA0002"},
              {"songname":"晴天","singername":"周杰伦","duration":272,"hash":"AAAA0003"},
              {"songname":"晴天","singername":"周杰伦、Another","duration":269,"hash":"AAAA0004"},
              {"songname":"晴天","singername":"周杰伦","duration":269,"hash":"../evil"}
            ]}}
            """#.utf8)
        #expect(KuGou.hash(in: results, for: track) == "AAAA0004")
    }

    @Test func takesTheFirstLyricsFiledUnderTheSong() throws {
        let results = Data(#"""
            {"candidates":[
              {"id":"1","accesskey":"K1","song":"晴天 (Cover)","singer":"Someone Else","duration":270000},
              {"id":2,"accesskey":"K2","song":"晴天","singer":"周杰伦","duration":269792},
              {"id":"3","accesskey":"K3","song":"晴天","singer":"周杰伦","duration":270000}
            ]}
            """#.utf8)
        let pick = try #require(KuGou.candidate(in: results, for: track))
        #expect(pick.id == "2" && pick.key == "K2")
        #expect(KuGou.candidate(in: Data("{}".utf8), for: track) == nil)
    }
}
