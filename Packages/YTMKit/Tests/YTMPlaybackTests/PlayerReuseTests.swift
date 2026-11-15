import Foundation
import Testing
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

/// What the player fetches once and reuses, or starts without waiting for:
/// streams kept for songs played again, a playlist's later batches, a radio
/// and lyrics already on their way.
@MainActor
struct PlayerReuseTests {
    @Test func aPlaylistCardStartsOnItsFirstBatchAndQueuesTheRest() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a", "b"), songs("c", "a"), songs("d")] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        #expect(rig.player.current?.id == "a", "started on the first batch")
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c", "a", "d"], "in order, a song it holds twice too")
        #expect(!rig.music.calls.contains { $0.hasPrefix("playlist") || $0.hasPrefix("tracks") })
    }

    @Test func headerPlayOnAPartlyLoadedPlaylistStartsAtOnce() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a", "b"), songs("c"), songs("d")] }
        let page = Page(
            header: PageHeader(title: "List", playlistId: "PL"),
            sections: [.tracks(TrackSection(title: "", tracks: songs("a", "b"), mode: .section))],
            more: .tracks(token: "PL#1", sectionIndex: 0)
        )
        await rig.player.play(page)
        #expect(rig.player.current?.id == "a", "the page's tracks start at once")
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(!rig.music.calls.contains { $0.hasPrefix("playlist") }, "nothing the page holds is asked for again")
        #expect(rig.music.calls.filter { $0.hasPrefix("more") } == ["more PL#1", "more PL#2"])

        await rig.player.play(page)
        rig.player.play(songs("x"))
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["x"], "another queue drops the batches still to come")
    }

    @Test func withShuffleOnAPlaylistLoadsWholeBeforeItPlays() async {
        let rig = await started()
        rig.settings.value.shuffle = .on
        rig.player.apply(rig.settings.value)
        let all = (0..<30).map { song("\($0)") }
        rig.music.set {
            $0.radios["PL"] = all
            $0.playlistBatches["PL"] = [Array(all[..<2]), Array(all[2...])]
        }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        #expect(rig.player.queue.count == 30, "a card's first song is picked from the whole list")
        let page = Page(
            header: PageHeader(title: "List", playlistId: "PL"),
            sections: [.tracks(TrackSection(title: "", tracks: Array(all[..<2]), mode: .section))],
            more: .tracks(token: "PL#1", sectionIndex: 0)
        )
        await rig.player.play(page)
        #expect(rig.player.queue.count == 30, "and header Play's")
        await rig.settle()
        #expect(rig.music.calls.contains("playlist PL"))
        #expect(!rig.music.calls.contains { $0.hasPrefix("page") || $0.hasPrefix("more") }, "no batches to reshuffle for")
    }

    @Test func batchesArrivingAfterShuffleIsTurnedOnKeepThePlaylistsOrder() async {
        let rig = await started()
        let all = (0..<12).map { song("\($0)") }
        rig.music.set { $0.playlistBatches["PL"] = [Array(all[..<6]), Array(all[6...])] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        rig.settings.value.shuffle = .on
        rig.player.apply(rig.settings.value)
        await rig.settle()
        #expect(rig.player.queue.count == 12)
        rig.settings.value.shuffle = .off
        rig.player.apply(rig.settings.value)
        #expect(rig.player.queue.items.map(\.id) == all.map(\.id), "unshuffled, the batch follows the playlist's last song")
    }

    @Test func clearingUpNextDropsAPlaylistsBatchesStillToCome() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a", "b"), songs("c"), songs("d")] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        rig.player.clearUpcoming()
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a"])
    }

    @Test func clearingUpNextLeavesACardStillLoadingToPlay() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        rig.music.set {
            $0.held = ["ALB"]
            $0.radios["ALB"] = songs("x", "y")
        }
        let tap = Task { await rig.player.play(Card(kind: .album, id: "ALB", title: "Album")) }
        await rig.yieldToTasks()
        #expect(rig.player.pendingPlay != nil, "the album is still loading")
        rig.player.clearUpcoming()
        rig.music.release("ALB")
        await tap.value
        #expect(rig.player.current?.id == "x")
    }

    @Test func aSkipWhileASongsRadioLoadsWaitsForIt() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("b", "c") }
        rig.player.startRadio(from: song("a"))
        rig.player.next()
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.music.calls.filter { $0 == "radio a" }.count == 1, "asked for once")
    }

    @Test func aSkipWhileTheNextSongQueuesLeavesItsResolveRunning() async {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 190
        rig.player.onTick()
        rig.player.next()
        await rig.yieldToTasks()
        rig.music.release("b")
        await rig.settle()
        #expect(rig.playing?.id.hasPrefix("b#") == true)
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "the resolve ahead, not a second one")
    }

    @Test func previousPlaysTheSongBeforeFromItsKeptStream() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.next()
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 1
        let warms = rig.audio.warmed.count
        rig.player.previous()
        await rig.settle()
        #expect(rig.playing?.id.hasPrefix("a#") == true)
        #expect(rig.music.calls.filter { $0 == "stream a" }.count == 1)
        await rig.soundStarts()
        #expect(rig.audio.warmed.dropFirst(warms).contains { $0.id.hasPrefix("b#") }, "the song after has its start fetched again")
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "from its kept stream")
    }

    @Test func repeatOneLoopsWithoutResolvingAgain() async throws {
        let rig = await started()
        rig.settings.value.repeatMode = .one
        rig.player.apply(rig.settings.value)
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        let queued = try #require(rig.audio.next)
        rig.player.handle(.advanced(id: queued.id))
        await rig.settle()
        #expect(rig.music.calls.filter { $0 == "stream a" }.count == 1)
        #expect(rig.audio.warmed.isEmpty, "the file playing is not fetched again")
    }

    @Test func lyricsComeAheadAndStayForASongPlayedAgain() async {
        let rig = await started()
        let words = Lyrics(lines: ["la"])
        rig.music.set { $0.lyrics["a"] = words }
        rig.player.showsLyrics = true
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .loaded(words))
        await rig.soundStarts()
        #expect(rig.music.calls.contains("lyrics b"), "the next song's, fetched ahead while shown")
        rig.player.next()
        #expect(rig.player.lyrics == .unavailable, "at once, with no loading in between")
        await rig.settle()
        rig.audio.currentTime = 1
        rig.player.previous()
        #expect(rig.player.lyrics == .loaded(words))
        #expect(rig.music.calls.filter { $0.hasPrefix("lyrics") } == ["lyrics a", "lyrics b"], "each asked for once")
    }

    @Test func lyricsThatFailedAreAskedForAgain() async {
        let rig = await started()
        rig.music.set { $0.lyricsFail = true }
        rig.player.showsLyrics = true
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.player.lyricsLoad?.value
        let words = Lyrics(lines: ["la"])
        rig.music.set {
            $0.lyricsFail = false
            $0.lyrics["a"] = words
        }
        rig.player.showsLyrics = false
        rig.player.showsLyrics = true
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .loaded(words))
        #expect(rig.music.calls.filter { $0 == "lyrics a" }.count == 2, "a failure is not kept")
    }
}
