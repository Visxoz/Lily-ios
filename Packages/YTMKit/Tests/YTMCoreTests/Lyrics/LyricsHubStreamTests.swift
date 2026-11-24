import Foundation
import Testing
@testable import YTMCore

@Suite struct LyricsHubStreamTests {
    private let lineTimed = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1.0" end="2.0">Alpha</p></div></body></tt>"#
    private let wordTimed = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1.0" end="2.0"><span begin="1.0" end="1.5">Al</span><span begin="1.5" end="2.0">pha</span></p></div></body></tt>"#

    private func event(_ provider: String, _ results: [String: String]) throws -> [UInt8] {
        let data = try JSONSerialization.data(withJSONObject: ["provider": provider, "results": results])
        return Array("event: provider\r\ndata: \(String(decoding: data, as: UTF8.self))\r\n\r\n".utf8)
    }

    @Test func stopsOnceNothingToComeCouldBeChosen() async throws {
        #expect(TTML.lyrics(Data(wordTimed.utf8), source: "")?.isWordSynced == true)
        let (stream, continuation) = AsyncStream.makeStream(of: UInt8.self)
        for byte in try event("binimum", ["lyrics": lineTimed]) + event("golyrics", [:]) + event("spicy", ["lyrics": wordTimed]) {
            continuation.yield(byte)
        }
        // The answer stays open, as the slowest sites' would.
        let found = await LyricsSite.within(.seconds(5)) { await LyricsHub.found(streaming: stream) }
        continuation.finish()
        #expect(found?.apple.map(\.source) == ["Source: Spicy Lyrics", "Source: lrc.red"])
        #expect(found?.answered == ["binimum", "golyrics", "spicy"])
    }

    @Test func readsOnWhileABetterSiteMayAnswer() async throws {
        let golyrics = String(decoding: try JSONSerialization.data(withJSONObject: ["ttml": wordTimed]), as: UTF8.self)
        let (stream, continuation) = AsyncStream.makeStream(of: UInt8.self)
        for byte in try event("spicy", ["lyrics": wordTimed]) + event("golyrics", ["lyrics": golyrics]) { continuation.yield(byte) }
        continuation.finish()
        let found = await LyricsHub.found(streaming: stream)
        #expect(found.apple.map(\.source) == ["Source: Better Lyrics", "Source: Spicy Lyrics"])
    }

    @Test func aStallKeepsWhatCame() async throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
        for byte in try event("kugou", ["lyrics": "[00:01.00]Alpha"]) + Array("data: {\"provi".utf8) { continuation.yield(byte) }
        continuation.finish(throwing: URLError(.timedOut))
        let found = await LyricsHub.found(streaming: stream)
        #expect(found.others.map(\.source) == ["Source: KuGou"])
        #expect(found.answered == ["kugou"])
    }

    @Test func lrcRedIsAskedOnlyWhenTheHubsMissIsNotItsOwn() throws {
        let plain = Track(id: "v", title: "Alpha", artists: [ArtistRef(id: nil, name: "Beta")], duration: 200)
        let missed = LyricsHub.Found(answered: ["binimum"])
        #expect(YTMusic.hubMissedLrcRed(missed, for: plain))
        #expect(!YTMusic.hubMissedLrcRed(LyricsHub.Found(answered: ["golyrics"]), for: plain), "binimum never answered")
        let lines = try #require(TTML.lyrics(Data(lineTimed.utf8), source: LrcRed.source))
        #expect(!YTMusic.hubMissedLrcRed(LyricsHub.Found(apple: [lines], answered: ["binimum"]), for: plain), "line timing only")
        let credited = Track(id: "v", title: "Alpha (feat. Gamma)", artists: [ArtistRef(id: nil, name: "Beta")], duration: 200)
        #expect(!YTMusic.hubMissedLrcRed(missed, for: credited), "lrc.red is searched without the credit")
        let traditional = Track(id: "v", title: "晴天", artists: [ArtistRef(id: nil, name: "周杰倫")], duration: 269)
        #expect(!YTMusic.hubMissedLrcRed(missed, for: traditional), "lrc.red is searched again in Simplified")
    }
}
