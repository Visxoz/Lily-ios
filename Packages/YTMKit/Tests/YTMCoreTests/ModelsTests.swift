import Foundation
import Testing
@testable import YTMCore

@Test func joinsArtists() {
    #expect(ArtistRef.joined([.init(id: nil, name: "A"), .init(id: nil, name: "B"), .init(id: nil, name: "C")]) == "A, B, C")
}

@Test func listedArtistsAreLeftOutByNameWhateverItsCase() {
    let blocked = Blocked(listed: ListedArtists(["Aria Vale", "kelvin", "Aria vale"]))
    let listed = Track(id: "a", title: "", artists: [ArtistRef(id: "UC1", name: "ARIA VALE")])
    let other = Track(id: "b", title: "", artists: [ArtistRef(id: nil, name: "Pond")])
    #expect(blocked.has(listed) && !blocked.has(other))
    #expect(blocked.has(Track(id: "k", title: "", artists: [ArtistRef(id: nil, name: "\u{212A}ELVIN")])), "a capital folding to ASCII")
    #expect(blocked.listed?.count == 2, "each name once")
    #expect(ListedArtists(["SLØWBREAKER"]).has("sløwbreaker"), "a capital beyond ASCII")
    let (kept, index) = [listed, other, listed].removingSongs(by: blocked, sparing: 2)
    #expect(kept.map(\.id) == ["b", "a"] && index == 1, "bar the one chosen")
    #expect([listed, other].leavingOut(blocked).map(\.id) == ["b"])
    #expect(Blocked().isEmpty && !Blocked().has(listed))
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

@Test func linksNameEachKindAndSkipPagesWithoutOne() {
    #expect(Track(id: "dQw4w9WgXcQ", title: "").link == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(Card(kind: .song, id: "v", title: "").link == "https://music.youtube.com/watch?v=v")
    #expect(Route.album("MPREb_x").link == "https://music.youtube.com/browse/MPREb_x")
    #expect(Route.playlist("PLx").link == "https://music.youtube.com/playlist?list=PLx")
    #expect(Route.artist("UCx").link == "https://music.youtube.com/channel/UCx")
    #expect(Card(kind: .artist, id: "UCx", title: "").link == Route.artist("UCx").link)
    #expect(Card(kind: .genre, id: "x", title: "").link == nil)
    #expect(Route.home.link == nil)
    #expect(Route.search("x").link == nil)
}

@Test func decodesASearchRouteSavedBeforeSearchKinds() throws {
    let saved = Data(#"{"search":{"_0":"x"}}"#.utf8)
    #expect(try JSONDecoder().decode(Route.self, from: saved) == .search("x"))
}

@Test func decodesAPageHeaderSavedBeforeItReadOwnershipAndLibraryState() throws {
    let saved = Data(#"{"label":"Playlist","title":"Road trip","subtitle":"","meta":"12 songs","banner":false}"#.utf8)
    let header = try JSONDecoder().decode(PageHeader.self, from: saved)
    #expect(header.title == "Road trip" && header.editable == nil && header.saved == nil && header.count == nil)
}
