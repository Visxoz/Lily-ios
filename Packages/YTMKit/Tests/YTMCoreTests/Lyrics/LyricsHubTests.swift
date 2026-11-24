import Foundation
import Testing
@testable import YTMCore

@Suite struct LyricsHubTests {
    private func event(_ provider: String, _ results: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["provider": provider, "results": results])
        return "event: provider\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    /// The whole answer, as one that has already ended.
    private func read(_ text: String) async -> LyricsHub.Found {
        let (stream, continuation) = AsyncStream.makeStream(of: UInt8.self)
        for byte in text.utf8 { continuation.yield(byte) }
        continuation.finish()
        return await LyricsHub.found(streaming: stream)
    }

    @Test func readsEachSitesLyricsBestFirst() async throws {
        let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1.0" end="2.0">Alpha</p></div></body></tt>"#
        let qrc = #"<QrcInfos><Lyric_1 LyricContent="[1000,1000]Alpha(1000,1000)"/></QrcInfos>"#
        let stream = try [
            "event: metadata\r\ndata: {\"song\":\"Dummy Song\"}\r\n\r\n",
            event("lrclib", ["synced": "[00:01.00]Alpha", "plain": "Alpha"]),
            event("qq", ["lyrics": String(decoding: try JSONSerialization.data(withJSONObject: ["lyrics": qrc]), as: UTF8.self)]),
            event("binimum", ["lyrics": ttml, "timingType": "line"]),
            event("golyrics", ["lyrics": String(decoding: try JSONSerialization.data(withJSONObject: ["ttml": ttml]), as: UTF8.self)]),
            event("kugou", ["lyrics": #"{"lyrics":"[00:01.00]Alpha"}"#]),
            event("someday", ["lyrics": "Alpha"]),
            "data: [DONE]\n\n",
        ].joined()
        let found = await read(stream)
        #expect(found.apple.map(\.source) == ["Source: Better Lyrics", "Source: lrc.red"])
        #expect(found.others.map(\.source) == ["Source: QQ Music", "Source: KuGou", "Source: LRCLIB"])
        #expect(found.others.first?.isWordSynced == true)
        #expect((found.apple + found.others).allSatisfy { $0.lines == ["Alpha"] && $0.starts == [1] })
        #expect(found.answered == ["lrclib", "qq", "binimum", "golyrics", "kugou", "someday"])
        #expect(await read("<html>busy</html>") == LyricsHub.Found())
    }

    @Test func readsWhenAPassWasIssuedAndLapses() throws {
        let claims = Data(#"{"iat":1795411254,"exp":1795497654,"ip":"192.0.2.1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let pass = try #require(HubPass.Saved(jwt: "header.\(claims).signature"))
        #expect(pass.issued == Date(timeIntervalSince1970: 1_795_411_254))
        #expect(pass.expiry.timeIntervalSince(pass.issued) == 86_400)
        #expect(HubPass.Saved(jwt: "not a token") == nil)
        #expect(HubPass.Saved(jwt: "a.e30.c") == nil, "no times")
    }

    @Test func aSlowOrFailingSiteIsNone() async {
        #expect(await LyricsSite.within(.seconds(5)) { 1 } == 1)
        #expect(await LyricsSite.within(.seconds(5)) { () throws -> Int? in throw CancellationError() } == nil)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await LyricsSite.within(.milliseconds(50)) { () async throws -> Int? in
            try await Task.sleep(for: .seconds(10))
            return 1
        } == nil)
        #expect(clock.now - started < .seconds(2), "the slow fetch is cancelled")
    }
}
