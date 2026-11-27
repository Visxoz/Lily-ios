import Foundation
import Testing
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct PlayerSettingsTests {
    @Test func automixQueuesTheNextSongByItsReachInPlaceOfTheCrossfade() async throws {
        let rig = await started()
        rig.settings.value.crossfade = true
        rig.settings.value.automix = true
        rig.player.apply(rig.settings.value)
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 160
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next == nil, "not yet")
        rig.audio.currentTime = 162
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true, "queued by the longest blend, its varispeed and the silence it may cut")
        #expect(rig.audio.nextTransition == .automix)
    }

    /// Plays two songs to 30 s from the first's end, by which Automix has queued the second, though a crossfade hasn't.
    private func automixed(_ rig: Rig, automix: Bool = true) async {
        await playing(rig, [song("a", album: "x", number: 1), song("b", album: "y", number: 1)], automix: automix)
        rig.audio.currentTime = 170
        rig.player.onTick()
        await rig.settle()
    }

    /// Plays `tracks` to the first's first sound, with Automix on or else a crossfade.
    private func playing(_ rig: Rig, _ tracks: [Track], automix: Bool = true) async {
        rig.settings.value.automix = automix
        rig.settings.value.crossfade = !automix
        rig.player.apply(rig.settings.value)
        rig.player.play(tracks)
        await rig.settle()
        await rig.soundStarts()
        await rig.settle()
    }

    /// The songs asked where they are sung, in order of ID.
    private func sungAsked(_ rig: Rig) -> [String] {
        rig.music.calls.filter { $0.hasPrefix("sung") }.sorted()
    }

    @Test func automixIsToldWhereBothSongsAreSung() async throws {
        let rig = await started()
        rig.music.set { $0.sung = ["a": [10..<20], "b": [1..<5]] }
        await automixed(rig)
        #expect(rig.audio.nextSung == Sung(current: [10..<20], next: [1..<5]))
        #expect(sungAsked(rig) == ["sung a", "sung b"], "each asked once")
    }

    @Test func theLyricsShownStandInForAskingWhereSongsAreSung() async throws {
        let rig = await started()
        rig.player.showsLyrics = true
        rig.music.set {
            $0.lyrics["a"] = Lyrics(lines: ["la"], starts: [10])
            $0.sung["b"] = [1..<5]
        }
        await automixed(rig)
        #expect(rig.audio.nextSung == Sung(current: [10..<15]), "a song without lyrics isn't asked")
        #expect(sungAsked(rig).isEmpty)
    }

    @Test func theLyricsShownWinOverYouTubesOnceTheyLand() async throws {
        let rig = await started()
        rig.music.set {
            $0.lyrics["a"] = Lyrics(lines: ["la"], starts: [10])
            $0.sung["a"] = [1..<2]
        }
        await playing(rig, [song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        #expect(rig.music.calls.contains("sung a"), "YouTube's first")
        rig.player.showsLyrics = true
        await rig.player.lyricsLoad?.value
        rig.audio.currentTime = 170
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.nextSung.current == [10..<15])
    }

    @Test func noOneIsAskedWhereSongsAreSungUnlessAutomixWillPlayTheNext() async throws {
        for endOfSong in [false, true] {
            let rig = await started()
            rig.music.set { $0.sung = ["a": [10..<20], "b": [1..<5]] }
            if endOfSong { rig.player.setSleepTimer(.endOfSong) }
            await automixed(rig, automix: endOfSong)
            #expect(sungAsked(rig).isEmpty, "end of song: \(endOfSong)")
        }
    }

    @Test func turningAutomixOffStopsTheLookupsOfWhereSongsAreSung() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["sung a", "sung b"] }
        await automixed(rig)
        for automix in [false, true] {
            rig.settings.value.automix = automix
            rig.player.apply(rig.settings.value)
        }
        await rig.settle()
        for id in ["a", "b"] {
            #expect(rig.music.calls.filter { $0 == "sung \(id)" }.count == 2, "asked afresh")
            rig.music.release("sung \(id)")
        }
        await rig.settle()
        #expect(rig.music.calls.filter { $0.hasPrefix("cancelled") }.sorted() == ["cancelled sung a", "cancelled sung b"])
    }

    @Test func aSongThatLeavesTheCurrentAndNextIsNoLongerAsked() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["sung a"] }
        await playing(rig, [song("a", album: "x", number: 1), song("b", album: "y", number: 1), song("c", album: "z", number: 1)])
        rig.player.next()
        await rig.settle()
        await rig.soundStarts()
        rig.music.release("sung a")
        await rig.settle()
        #expect(rig.music.calls.contains("cancelled sung a"))
    }

    @Test(arguments: [(song("s"), false), (song("s"), true), (nil, false)])
    func aVideoNextIsAskedWhereItIsSungOnlyOnceItWontBeSwapped(version: Track?, fails: Bool) async throws {
        let rig = await started()
        rig.music.set {
            $0.songVersions["v"] = version
            $0.held = ["s"]
            if fails { $0.failing = ["s"] }
        }
        await playing(rig, [song("a", album: "x", number: 1), song("v", video: true)])
        // Asked again while the song version's stream resolves, which may yet fail.
        rig.player.prefetchSung()
        if version != nil { #expect(sungAsked(rig) == ["sung a"], "waits for the swap") }
        rig.music.release("s")
        await rig.settle()
        #expect(sungAsked(rig) == ["sung a", version == nil || fails ? "sung v" : "sung s"])
    }

    @Test func aVideoNextWhoseSongVersionIsDownloadedIsStillAskedWhereItIsSung() async throws {
        let rig = await started()
        rig.music.set { $0.songVersions["v"] = song("s") }
        rig.player.downloads.index.singles = [song("s")]
        rig.player.downloads.index.songs = ["s": DownloadedSong(track: song("s"), stream: FakeMusic.stream("s"), added: .now)]
        await playing(rig, [song("a", album: "x", number: 1), song("v", video: true)])
        #expect(rig.player.localStream("s") != nil)
        #expect(sungAsked(rig) == ["sung a", "sung v"])
    }

    @Test func aVideoNextWhoseSongVersionsStreamIsDroppedIsAskedWhereItIsSung() async throws {
        let rig = await started()
        rig.music.set {
            $0.songVersions["v"] = song("s")
            $0.held = ["s"]
        }
        await playing(rig, [song("a", album: "x", number: 1), song("v", video: true)])
        rig.settings.value.quality = .low
        rig.player.apply(rig.settings.value)
        rig.music.release("s")
        await rig.settle()
        #expect(sungAsked(rig) == ["sung a", "sung v"])
    }

    @Test func aNewCrossfadeLengthQueuesTheNextSongAgain() async throws {
        let rig = await started()
        rig.settings.value.crossfade = true
        rig.player.apply(rig.settings.value)
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 176
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)

        rig.settings.value.crossfadeSeconds = 3
        rig.player.apply(rig.settings.value)
        #expect(rig.audio.next == nil, "queued with the old length, so dropped")
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
        #expect(rig.audio.nextTransition == .crossfade(3))
    }

    @Test func unpluggingTheDevicePlayingPauses() async throws {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.outputUnplugged()
        #expect(!rig.player.isPlaying)
        #expect(rig.audio.log.last == "pause")
        #expect(rig.player.current?.id == "a", "the queue and the song stay")
        #expect(await toasts.next() == "Paused, as the device playing was unplugged")
    }

    @Test func unpluggingPlaysOnWithTheSettingOffAndLeavesAPauseAlone() async throws {
        let rig = await started()
        rig.settings.value.pauseOnUnplug = false
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.outputUnplugged()
        #expect(rig.player.isPlaying)
        #expect(!rig.audio.log.contains("pause"))
        #expect(!rig.audio.pauseOnUnplug, "nor does the engine pause itself")

        rig.settings.value.pauseOnUnplug = true
        rig.player.setPaused(true)
        rig.player.outputUnplugged()
        #expect(rig.audio.log.filter { $0 == "pause" }.count == 1, "already paused, so nothing more")
    }

    @Test func theCacheCapFollowsTheSettings() async throws {
        let rig = await started()
        #expect(rig.audio.cacheLimitBytes == Settings().audioCacheBytes, "set once the settings are read")
        rig.settings.value.audioCacheBytes = 500_000_000
        rig.player.apply(rig.settings.value)
        #expect(rig.audio.cacheLimitBytes == 500_000_000)
    }
}
