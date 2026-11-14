import Foundation
import Testing
@testable import YTMCore

@Test func joinsArtists() {
    #expect(ArtistRef.joined([.init(id: nil, name: "A"), .init(id: nil, name: "B"), .init(id: nil, name: "C")]) == "A, B, C")
}

@Test func badgesPremiumFormatsAtTheirNominalBitrate() throws {
    let url = try #require(URL(string: "https://r1.googlevideo.com/x"))
    func badge(_ itag: Int, _ codec: AudioCodec, _ bitrate: Int) -> String {
        ResolvedStream(
            url: url, headers: [:], itag: itag, codec: codec, contentLength: 1, bitrate: bitrate,
            duration: nil, loudnessDb: nil
        ).badge
    }
    #expect(badge(774, .opus, 284_000) == "OPUS 256")
    #expect(badge(141, .aac, 262_000) == "AAC 256")
    #expect(badge(251, .opus, 135_400) == "OPUS 135")
}
