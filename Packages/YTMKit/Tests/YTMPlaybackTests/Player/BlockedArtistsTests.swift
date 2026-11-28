import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

/// Each `song(id)` has its own artist ID, `UC<id>`, though all are named "Artist", so blocks here have names of their own.
@MainActor
struct BlockedArtistsTests {
    private func block(_ ids: String..., in rig: Rig) {
        rig.settings.value.blockedArtists = ids.map { ArtistRef(id: "UC\($0)", name: "Artist \($0)") }
        rig.player.apply(rig.settings.value)
    }

    @Test func playLeavesOutBlockedArtistsButTheSongChosen() async {
        let rig = await started()
        block("b", "c", in: rig)
        rig.player.play(songs("a", "b", "c", "d"), startAt: 1)
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "d"])
        #expect(rig.player.current?.id == "b")
    }

    @Test func saysSoWhenEverySongIsBlocked() async {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        block("a", in: rig)
        rig.player.play(songs("a"))
        #expect(rig.player.current == nil)
        #expect(await toasts.next() == "Every song here is by a blocked artist")
    }

    @Test func playLeavesOutListedArtistsButTheSongChosen() async {
        let rig = await started()
        rig.settings.listed = ListedArtists(["ARTIST"])
        rig.player.play(songs("a", "b"), startAt: 0)
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a"])
        #expect(rig.player.current?.id == "a")
    }

    @Test func aLongPlaylistAllBlockedAddsNoLaterPages() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a"), songs("c")] }
        rig.player.play(songs("x"))
        await rig.settle()
        block("a", in: rig)
        let page = Page(
            header: PageHeader(title: "List", playlistId: "PL"),
            sections: [.tracks(TrackSection(title: "", tracks: songs("a"), mode: .section))],
            more: .tracks(token: "PL#1")
        )
        await rig.player.play(page)
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["x"], "the queue playing is left alone")
    }

    @Test func unblockingAnotherLeavesASongChosenPlaying() async {
        let rig = await started()
        block("a", "c", in: rig)
        rig.player.play(songs("a", "b"), startAt: 0)
        await rig.settle()
        await rig.soundStarts()
        block("a", in: rig)
        await rig.settle()
        #expect(rig.player.current?.id == "a" && rig.player.isPlaying)
    }

    @Test func autoplayLeavesOutBlockedArtists() async {
        let rig = await started()
        block("b", in: rig)
        rig.music.set { $0.radios["a"] = songs("a", "b", "c") }
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.player.queue.items.map(\.id) == ["a", "c"])
    }

    @Test func blockingTakesTheArtistOutOfTheQueueAndSkipsTheSongPlaying() async {
        let rig = await started()
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        block("a", "c", in: rig)
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.player.queue.items.map(\.id) == ["b"], "the song skipped too, so a repeat never comes back to it")
    }

    @Test func blockingLeavesASongPausedWhereItIs() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.setPaused(true)
        block("a", in: rig)
        await rig.settle()
        #expect(rig.player.current?.id == "a" && !rig.player.isPlaying, "skipping would start playback")
        #expect(rig.player.queue.items.map(\.id) == ["a", "b"])
    }

    @Test func blockingALoneSongOnRepeatStopsRatherThanRestartingIt() async {
        let rig = await started()
        rig.settings.value.repeatMode = .all
        rig.player.apply(rig.settings.value)
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        let played = rig.audio.played.count
        block("a", in: rig)
        await rig.settle()
        #expect(!rig.player.isPlaying && rig.player.current?.id == "a")
        #expect(rig.audio.played.count == played, "not restarted")
    }

    @Test func blockingTheLastSongStopsRatherThanAutoplayingItsRadio() async {
        let rig = await started()
        // Its radio, queued as it started, brings nothing new.
        rig.music.set { $0.radios["a"] = songs("a") }
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        let played = rig.audio.played.count
        block("a", in: rig)
        await rig.settle()
        #expect(!rig.player.isPlaying && rig.player.current?.id == "a", "stopped on it")
        #expect(rig.audio.played.count == played, "not restarted")
        #expect(rig.music.calls.filter { $0 == "radio a" }.count == 1, "no radio of it asked for")
    }

    @Test func blockingTheLastSongDropsTheRadioAutoplayQueuedFromIt() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("x", "y") }
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.player.queue.items.map(\.id) == ["a", "x", "y"])
        block("a", in: rig)
        await rig.settle()
        #expect(!rig.player.isPlaying && rig.player.current?.id == "a", "stopped on it")
        #expect(rig.player.queue.items.map(\.id) == ["a"])
    }

    @Test func blockingTheLastSongPausedDropsItsRadioToo() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("x", "y") }
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.setPaused(true)
        block("a", in: rig)
        await rig.settle()
        #expect(!rig.player.isPlaying && rig.player.current?.id == "a", "left where it is")
        #expect(rig.player.queue.items.map(\.id) == ["a"])
    }

    /// A fresh copy kept in the rig's store, so the list loads from it and never from the network.
    private func keepAIList(in rig: Rig) throws {
        let file = rig.store.aiArtists
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("artist,id\n" + (0..<AIArtists.minNames).map { "Artist \($0),\($0)\n" }.joined()).utf8).write(to: file)
    }

    /// By an artist on the kept list, which no `song(id)` is.
    private func aiSong(_ id: String) -> Track {
        var track = song(id)
        track.artists = [ArtistRef(id: nil, name: "Artist 0")]
        return track
    }

    @Test func turningBlockAIOnTakesTheListsSongsOutButTheOnePlaying() async throws {
        let rig = await started()
        try keepAIList(in: rig)
        rig.player.play([aiSong("a"), song("b"), aiSong("c"), song("d")])
        await rig.settle()
        await rig.soundStarts()
        rig.settings.value.blockAI = true
        rig.player.apply(rig.settings.value)
        await rig.player.aiArtistsLoad?.value
        await rig.settle()
        #expect(rig.settings.listed?.count == AIArtists.minNames)
        #expect(rig.player.current?.id == "a" && rig.player.isPlaying, "not skipped")
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "d"])
    }

    @Test func aListThatFailedAsBlockAIWentOnTakesItsSongsOutOnceItLoads() async throws {
        let rig = await started()
        rig.player.play([aiSong("a"), song("b"), aiSong("c"), song("d")])
        await rig.settle()
        await rig.soundStarts()
        // On without a load, as after one failed with no copy kept.
        rig.player.applied?.blockAI = true
        rig.settings.value.blockAI = true
        rig.player.aiArtistsPurgeOwed = true
        try keepAIList(in: rig)
        rig.player.aiArtistsDue = .now
        rig.player.refreshAIArtistsIfDue()
        await rig.player.aiArtistsLoad?.value
        await rig.settle()
        #expect(rig.settings.listed?.count == AIArtists.minNames)
        #expect(!rig.player.aiArtistsPurgeOwed)
        #expect(rig.player.current?.id == "a" && rig.player.isPlaying, "not skipped")
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "d"])
    }

    @Test func launchAndDueLoadsLeaveTheQueueAsItIs() async throws {
        let rig = Rig()
        try keepAIList(in: rig)
        var queue = Queue<Track>(seed: 1)
        queue.set(items: [aiSong("a"), song("b"), aiSong("c")], start: 0, shuffle: false)
        try rig.store.save(#require(SessionSnapshot(queue, position: 0, duration: 200)), to: .session)
        rig.settings.value.blockAI = true
        await rig.player.start()
        #expect(!rig.player.aiArtistsPurgeOwed)
        await rig.player.aiArtistsLoad?.value
        // The launch load may finish before the session is restored; this one comes after.
        rig.player.aiArtistsDue = .now
        rig.player.refreshAIArtistsIfDue()
        await rig.player.aiArtistsLoad?.value
        await rig.settle()
        #expect(rig.settings.listed?.count == AIArtists.minNames)
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c"])
    }

    @Test func turningBlockAIOffForgetsTheList() async throws {
        let rig = Rig()
        try keepAIList(in: rig)
        rig.settings.value.blockAI = true
        await rig.player.start()
        await rig.player.aiArtistsLoad?.value
        #expect(rig.settings.listed?.count == AIArtists.minNames)
        rig.settings.value.blockAI = false
        rig.player.apply(rig.settings.value)
        await rig.settle()
        #expect(rig.settings.listed == nil)
        #expect(rig.settings.blocked.isEmpty)
    }

    @Test func aFailedAIListIsAskedForAgainLaterEachTimeUpToADay() {
        let minutes = (0..<9).map { PlayerController.aiArtistsRetry(after: $0) / .seconds(60) }
        #expect(minutes == [15, 30, 60, 120, 240, 480, 960, 1440, 1440])
    }
}
