import Foundation
import Observation
import Testing
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

/// The player's logic against fake YouTube, engine and Last.fm: what it asks
/// for, what it hands the engine, and what it records, in ytm-native's terms.
@MainActor
struct PlayerControllerTests {
    private func started(_ rig: Rig = Rig()) async -> Rig {
        await rig.player.start()
        return rig
    }

    @Test func playsAnAlbumGaplesslyRecordingEachPlayOnce() async throws {
        let rig = await started()
        let album = [song("a", album: "x", number: 1), song("b", album: "x", number: 2), song("c", album: "x", number: 3)]
        rig.player.play(album)
        #expect(rig.player.isBuffering && rig.player.isPlaying)
        await rig.settle()
        let first = try #require(rig.playing)
        #expect(first.id.hasPrefix("a#"))
        #expect(first.loudnessDB == -3, "turned down by YouTube's loudness")
        await rig.soundStarts()
        #expect(!rig.player.isBuffering)
        #expect(rig.history.history.tracks.map(\.id) == ["a"])
        #expect(rig.music.calls.contains("stream b"), "the next stream is resolved ahead")
        let warmed = try #require(rig.audio.warmed.last, "and its start fetched")
        #expect(warmed.id.hasPrefix("b#") && warmed.cacheKey.hasPrefix("b-"))

        rig.audio.currentTime = 170
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next == nil, "not yet")
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        let next = try #require(rig.audio.next)
        #expect(next.id.hasPrefix("b#"))
        #expect(!rig.audio.nextCrossfades, "an album in order runs straight on")
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "queued from the prefetched stream")

        rig.player.handle(.advanced(id: next.id))
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.player.queue.currentIndex == 1)
        #expect(rig.history.history.tracks.map(\.id) == ["b", "a"])
        #expect(rig.audio.played.count == 1, "nothing loaded afresh")
        #expect(await rig.lastFM.nowPlaying == ["a", "b"])
    }

    @Test func fadesIntoSongsOfAnotherAlbumWithCrossfadeOn() async throws {
        let rig = await started()
        rig.settings.value.crossfade = true
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 176
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true, "queued earlier by the fade and the silence it may cut")
        #expect(rig.audio.nextCrossfades)
    }

    @Test func previousRestartsAfterThreeSecondsAsANewPlay() async {
        let rig = await started()
        rig.player.play(songs("a", "b"), startAt: 1)
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 10
        rig.player.previous()
        await rig.settle()
        #expect(rig.audio.seeks == [0])
        #expect(rig.player.current?.id == "b")
        #expect(await rig.lastFM.nowPlaying == ["b", "b"], "starting over is a new play")
        rig.audio.currentTime = 1
        rig.player.previous()
        await rig.settle()
        #expect(rig.player.current?.id == "a")
    }

    @Test func retriesAPremiumStreamOnTheFreeOneWithoutASecondPlay() async throws {
        let rig = Rig()
        rig.music.set {
            $0.signedIn = true
            $0.premium["a"] = true
        }
        await rig.player.start()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        #expect(rig.player.stream?.isPremium == true)
        await rig.soundStarts()
        rig.audio.currentTime = 60
        rig.player.handle(.failed(id: try #require(rig.playing).id, message: "Damaged."))
        await rig.settle()
        let retry = try #require(rig.audio.played.last)
        #expect(retry.from == 60, "carries on from where the sound got to")
        #expect(rig.player.stream?.isPremium == false)
        #expect(rig.music.calls.contains("stream a"))
        await rig.soundStarts()
        #expect(await rig.lastFM.nowPlaying == ["a"], "one play")
        #expect(rig.music.calls.filter { $0 == "report a" }.count == 1)
    }

    @Test func stopsAfterThreeSongsInARowFail() async {
        let rig = await started()
        rig.music.set { $0.failing = ["a", "b", "c"] }
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b", "c", "d"))
        await rig.settle()
        #expect(rig.player.current?.id == "c")
        #expect(!rig.player.isPlaying && !rig.player.isBuffering)
        #expect(await toasts.next() == "Couldn't play “Song a”: No audio.")
    }

    @Test func autoplayCarriesOnWithARadioOfTheLastSong() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("a", "b", "c") }
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c"], "queued as the last song starts, once each")

        rig.player.jump(to: 2)
        await rig.settle()
        await rig.soundStarts()
        rig.music.set { $0.radios["c"] = songs("d") }
        rig.player.handle(.finished)
        await rig.settle()
        #expect(rig.player.current?.id == "d", "the queue played out moves on to a radio")
    }

    @Test func startsARadioFromASong() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("b", "a", "c", "b") }
        rig.player.startRadio(from: song("a"))
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c"])
        #expect(rig.music.calls.filter { $0 == "radio a" }.count == 1, "autoplay doesn't ask for it again")
    }

    @Test func shuffleCyclesThroughSmartShuffleAndBack() async {
        let rig = await started()
        rig.music.set { $0.anyRadio = (0..<12).map { song("r\($0)") } }
        let own = (0..<20).map { song("\($0)") }
        rig.player.play(own)
        await rig.settle()
        rig.player.cycleShuffle()
        #expect(rig.settings.value.shuffle == .on)
        #expect(rig.player.queue.current?.id == "0" && rig.player.queue.items.map(\.id) != own.map(\.id))
        rig.player.cycleShuffle()
        await rig.settle()
        #expect(rig.settings.value.shuffle == .smart)
        #expect(!rig.player.queue.recommendedIndices.isEmpty, "recommendations mixed in")
        rig.player.cycleShuffle()
        #expect(rig.settings.value.shuffle == .off)
        #expect(rig.player.queue.items.map(\.id) == own.map(\.id), "taken out, and the order restored")
    }

    @Test func savesAndRestoresTheSessionPaused() async throws {
        let first = await started()
        first.player.play(songs("a", "b", "c"), startAt: 1)
        await first.settle()
        await first.soundStarts()
        first.audio.currentTime = 42
        first.player.persistSession()

        let second = await started(Rig(store: first.store))
        #expect(second.player.current?.id == "b")
        #expect(second.player.queue.count == 3)
        #expect(second.player.currentTime == 42)
        #expect(!second.player.isPlaying)
        #expect(second.audio.played.isEmpty, "nothing loads until played")
        second.player.togglePlayPause()
        await second.settle()
        let resumed = try #require(second.audio.played.last)
        #expect(resumed.item.id.hasPrefix("b#") && resumed.from == 42)
    }

    @Test func seeksBeforeLoadingStartThere() async throws {
        let first = await started()
        first.player.play(songs("a"))
        await first.settle()
        first.player.persistSession()
        let second = await started(Rig(store: first.store))
        second.player.seek(to: 80)
        #expect(second.player.currentTime == 80)
        #expect(second.player.lastSeek == Seek(count: 1, to: 80), "told, though nothing plays to move")
        second.player.togglePlayPause()
        await second.settle()
        #expect(try #require(second.audio.played.last).from == 80)
    }

    @Test func countsSeeksOnlyWithASong() async {
        let rig = await started()
        rig.player.seek(to: 10)
        #expect(rig.player.lastSeek.count == 0, "nothing to seek in")
        rig.player.play(songs("a"))
        await rig.settle()
        rig.player.seek(to: 30)
        rig.player.seek(to: 30)
        #expect(rig.player.lastSeek == Seek(count: 2, to: 30), "the same place again still counts")
        #expect(rig.audio.seeks.suffix(2) == [30, 30])
    }

    @Test func aQueueEditDropsTheQueuedSongNoLongerNext() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
        rig.player.moveQueue(fromOffsets: [2], toOffset: 1)
        #expect(rig.audio.next == nil)
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("c#") == true)
    }

    @Test func addsToTheQueueSayingSo() async {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.addToQueue(songs("a"))
        await rig.settle()
        #expect(rig.player.current?.id == "a", "an empty queue starts playing")
        rig.player.addToQueue(songs("c"))
        rig.player.playNext(songs("b1", "b2"))
        #expect(rig.player.queue.items.map(\.id) == ["a", "b1", "b2", "c"])
        #expect(await toasts.next() == "Added “Song c” to the queue")
        #expect(await toasts.next() == "2 songs play next")
    }

    @Test func ratingTogglesAndADislikeSkips() async {
        let rig = Rig()
        rig.music.set { $0.signedIn = true }
        await rig.player.start()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        rig.player.rate(.like)
        #expect(rig.player.rating == .like)
        rig.player.rate(.like)
        #expect(rig.player.rating == .none, "liked again takes it back")
        rig.player.rate(.dislike)
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.music.calls.filter { $0.hasPrefix("rate") } == ["rate a LIKE", "rate a INDIFFERENT", "rate a DISLIKE"])
    }

    @Test func aQualityChangeDropsStreamsResolvedAhead() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.player.prefetcher.has("b"))
        rig.settings.value.quality = .low
        rig.player.apply(rig.settings.value)
        #expect(!rig.player.prefetcher.has("b"), "resolved at the old quality")
    }

    @Test func aQualityChangeDropsAStreamStillResolvingAhead() async {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.settings.value.quality = .low
        rig.player.apply(rig.settings.value)
        rig.music.release("b")
        await rig.settle()
        #expect(!rig.player.prefetcher.has("b"), "resolved at the old quality as it was")
        #expect(rig.audio.warmed.isEmpty)
    }

    @Test func aSkipDuringAPrefetchWaitsOnItRatherThanAskingAgain() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.next()
        await rig.yieldToTasks()
        rig.music.release("b")
        await rig.settle()
        #expect(rig.playing?.id.hasPrefix("b#") == true)
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1)
        #expect(!rig.audio.warmed.contains { $0.id.hasPrefix("b#") }, "it plays rather than warms")
    }

    @Test func aPrefetchLandingOnceTheSongIsNoLongerNextIsNotWarmed() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.moveQueue(fromOffsets: [2], toOffset: 1)
        await rig.yieldToTasks()
        rig.music.release("b")
        await rig.settle()
        #expect(rig.audio.warmed.map { $0.id.prefix(2) } == ["c#"], "the song next now is warmed, and stays so")
        #expect(rig.player.prefetcher.has("b"), "kept for when it comes up")
    }

    @Test func aCrossfadeChangeWhileTheNextSongQueuesQueuesItAgain() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 186
        rig.player.onTick()
        rig.settings.value.crossfade = true
        rig.player.apply(rig.settings.value)
        rig.music.release("b")
        await rig.settle()
        #expect(rig.audio.next == nil, "queued with the old setting, so dropped")
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
        #expect(rig.audio.nextCrossfades)
    }

    @Test func aSmartShuffleTopUpPlacingNothingLeavesTheQueueAlone() async {
        let rig = await started()
        rig.settings.value.shuffle = .smart
        rig.player.apply(rig.settings.value)
        rig.player.play(songs("a", "b", "c", "d", "e", "f"))
        await rig.settle()
        let change = ObservedChange()
        withObservationTracking { _ = rig.player.queue } onChange: { change.mark() }
        rig.player.topUpSmartShuffle()
        #expect(!change.happened, "the pool is dry, so nothing was placed")
        await rig.settle()
    }

    @Test func aMediaServicesResetRebuildsAndCarriesOnWithoutASecondPlay() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 42
        rig.player.mediaServicesReset()
        await rig.settle()
        #expect(rig.audio.log.suffix(3).map { $0.prefix(4) } == ["stop", "rebu", "play"], "loaded once the graph is new")
        let played = try #require(rig.audio.played.last)
        #expect(played.item.id.hasPrefix("a#") && played.from == 42)
        await rig.soundStarts()
        #expect(rig.history.history.tracks.map(\.id) == ["a"])
    }

    @Test func normalisationChangesTheSongPlayingAndKeepsTheOneQueued() async throws {
        let rig = await started()
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "x", number: 2)])
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.audio.normalise)
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        let queued = try #require(rig.audio.next)
        rig.settings.value.normalise = false
        rig.player.apply(rig.settings.value)
        #expect(!rig.audio.normalise, "the engine applies it to what plays now")
        #expect(rig.audio.next?.id == queued.id, "the next song stays queued")
    }

    @Test func pullsTheBufferedFractionOfTheSongLoaded() async {
        let rig = await started()
        rig.audio.bufferedFraction = 0.4
        #expect(rig.player.bufferedFraction == 0, "nothing loaded")
        rig.player.play(songs("a"))
        await rig.settle()
        #expect(rig.player.bufferedFraction == 0.4)
    }

    @Test func shuffleOnAPageHeaderPlaysTheWholePlaylistShuffled() async {
        let rig = await started()
        rig.music.set { $0.radios["PLall"] = (0..<30).map { song("\($0)") } }
        let page = Page(header: PageHeader(title: "Artist", shufflePlaylistId: "PLall"), sections: [.tracks(TrackSection(title: "", tracks: songs("0", "1"), mode: .section))])
        await rig.player.play(page, shuffle: true)
        await rig.settle()
        #expect(rig.player.queue.count == 30)
        #expect(rig.settings.value.shuffle == .on, "Shuffle turns shuffle on")
    }

    @Test func loadsLyricsWhileShown() async {
        let rig = await started()
        rig.music.set { $0.lyrics["a"] = Lyrics(lines: ["la"]) }
        rig.player.play(songs("a", "b"))
        await rig.settle()
        #expect(rig.player.lyrics == .idle, "not asked for until shown")
        rig.player.showsLyrics = true
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .loaded(Lyrics(lines: ["la"])))
        rig.player.next()
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .unavailable)
    }
}

/// Premium versus free, as ytm-native's `resolve.rs` chooses.
struct StreamChooserTests {
    @Test func takesTheAccountAsWithoutPremiumAfterThreeSongsWithout() async throws {
        let music = FakeMusic()
        let chooser = StreamChooser(music: music)
        for id in ["a", "b", "c"] {
            let stream = try await chooser.resolve(videoId: id, wantPremium: true, signedIn: true, quality: .high)
            #expect(!stream.isPremium)
        }
        #expect(chooser.status == .notPremium)
        music.set { $0.calls = [] }
        _ = try await chooser.resolve(videoId: "d", wantPremium: true, signedIn: true, quality: .high)
        #expect(music.calls.first == "stream d", "straight to the free stream")
    }

    @Test func playsPremiumAndCountsIt() async throws {
        let music = FakeMusic()
        music.set { $0.premium["a"] = true }
        let chooser = StreamChooser(music: music)
        let stream = try await chooser.resolve(videoId: "a", wantPremium: true, signedIn: true, quality: .high)
        #expect(stream.isPremium && chooser.status == .premium)
        let free = try await chooser.resolve(videoId: "b", wantPremium: true, signedIn: true, quality: .high)
        #expect(!free.isPremium && !music.calls.contains("stream b"), "a known account takes the web client's best")
    }

    @Test func fallsBackToTheFreeStreamWhenPremiumFails() async throws {
        let music = FakeMusic()
        music.set { $0.premiumFails = true }
        let chooser = StreamChooser(music: music)
        let stream = try await chooser.resolve(videoId: "a", wantPremium: true, signedIn: true, quality: .high)
        #expect(!stream.isPremium && music.calls == ["premium a", "stream a"])
    }
}
