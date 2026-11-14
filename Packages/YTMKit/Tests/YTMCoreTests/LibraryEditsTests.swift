import Foundation
import Testing
@testable import YTMCore

/// ytm-native's `api/library.rs` tests.
@Suite struct LibraryEditsTests {
    private func json(_ text: String) throws -> JSON {
        try JSON(data: Data(text.utf8))
    }

    @Test func readsTheLikeButtonsState() throws {
        func next(_ status: String) throws -> JSON {
            try json(#"""
                {"playerOverlays":{"playerOverlayRenderer":{"actions":[{"likeButtonRenderer":
                  {"target":{"videoId":"x"},"likeStatus":"\#(status)","likesAllowed":true}}]}}}
                """#)
        }
        #expect(Rating(next: try next("LIKE")) == .like)
        #expect(Rating(next: try next("DISLIKE")) == .dislike)
        #expect(Rating(next: try next("INDIFFERENT")) == .none)
        #expect(Rating(next: try json("{}")) == .none)
    }

    @Test func readsWhetherAnEditSucceeded() throws {
        #expect(YTMusic.succeeded(try json(#"{"status":"STATUS_SUCCEEDED","playlistEditResults":[]}"#)))
        #expect(!YTMusic.succeeded(try json(#"{"status":"STATUS_FAILED"}"#)))
        #expect(!YTMusic.succeeded(try json("{}")))
    }

    @Test func listsOwnPlaylists() throws {
        let reply = try json(#"""
            {"contents":[{"addToPlaylistRenderer":{"playlists":[
              {"playlistAddToOptionRenderer":{"playlistId":"PL1","title":{"simpleText":"Road trip"},"containsSelectedVideos":"NONE"}},
              {"playlistAddToOptionRenderer":{"playlistId":"PL2","title":{"runs":[{"text":"Gym"}]},"containsSelectedVideos":"ALL"}},
              {"playlistAddToOptionRenderer":{"title":{"simpleText":"No ID"}}}]}}]}
            """#)
        #expect(PlaylistOption.list(in: reply) == [
            PlaylistOption(id: "PL1", title: "Road trip", contains: false),
            PlaylistOption(id: "PL2", title: "Gym", contains: true),
        ])
        #expect(PlaylistOption.list(in: try json("{}")) == nil)
    }
}
