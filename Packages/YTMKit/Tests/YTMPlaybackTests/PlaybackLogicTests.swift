import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct GaplessTests {
    private func track(_ album: String?, _ number: Int?) -> Track {
        Track(id: "x", title: "x", album: album.map { AlbumRef(id: $0, name: "Album") }, trackNumber: number)
    }

    @Test func runsAnAlbumOnWithoutFading() {
        let first = track("a", 1)
        #expect(GaplessScheduler.inAlbumOrder(first, track("a", 2)))
        #expect(GaplessScheduler.inAlbumOrder(first, track("a", nil)), "numbers unknown, assumed in order")
    }

    @Test func fadesBetweenAnythingElse() {
        let first = track("a", 1)
        #expect(!GaplessScheduler.inAlbumOrder(first, track("a", 5)), "shuffled")
        #expect(!GaplessScheduler.inAlbumOrder(first, track("b", 2)))
        #expect(!GaplessScheduler.inAlbumOrder(track(nil, nil), track(nil, nil)))
        #expect(!GaplessScheduler.inAlbumOrder(nil, first))
        #expect(!GaplessScheduler.inAlbumOrder(track("a", .max), track("a", 0)))
    }

    @Test func queuesEarlierByTheFadeAndTheSilenceItMayCut() {
        #expect(GaplessScheduler.lead(crossfade: 0) == 15)
        #expect(GaplessScheduler.lead(crossfade: 6) == 25)
    }

    @Test func queuesTheNextSongOnceNearTheEnd() {
        var scheduler = GaplessScheduler()
        let (a, b) = (song("a"), song("b"))
        func plan(at position: Double) -> (stale: Bool, due: (id: String, crossfade: Double)?) {
            scheduler.plan(position: position, duration: 200, started: true, current: a, next: b, crossfadeSeconds: 6)
        }
        #expect(plan(at: 170).due == nil, "too early, even with a fade")
        #expect(plan(at: 176).due?.id == "b")
        #expect(plan(at: 176).due?.crossfade == 6, "songs of different albums fade")
        scheduler.markTried("b")
        #expect(plan(at: 190).due == nil, "a failed attempt is not retried every tick")
    }
}

struct ScrobblerTests {
    private let ms = Duration.milliseconds

    @Test func countsOnlyTimePlayedThrough() {
        #expect(Scrobbler.playedThrough(moved: 0.25, elapsed: ms(250)) == 0.25, "a tick")
        #expect(Scrobbler.playedThrough(moved: 5, elapsed: ms(5000)) == 5, "a tick held up by the main actor")
        #expect(Scrobbler.playedThrough(moved: 30, elapsed: ms(250)) == 0, "a seek")
        #expect(Scrobbler.playedThrough(moved: -30, elapsed: ms(250)) == 0, "back")
        #expect(Scrobbler.playedThrough(moved: 0, elapsed: ms(250)) == 0, "paused")
    }

    @Test func countsHalfATrackOrFourMinutes() {
        #expect(!Scrobbler.counts(heard: 20, length: 30), "30 seconds is too short")
        #expect(!Scrobbler.counts(heard: 89, length: 180))
        #expect(Scrobbler.counts(heard: 90, length: 180))
        #expect(Scrobbler.counts(heard: 240, length: 1200), "four minutes of a long one")
        #expect(!Scrobbler.counts(heard: 239, length: 1200))
    }

    @Test func scrobblesOnceWhatWasHeardCounts() {
        var scrobbler = Scrobbler()
        scrobbler.start(song("a"))
        let start = ContinuousClock.now
        let result1 = scrobbler.heard(position: 0, length: 60, at: start)
        #expect(result1 == nil)
        let result2 = scrobbler.heard(position: 100, length: 60, at: start + .milliseconds(250))
        #expect(result2 == nil, "a seek counts nothing")
        var at = start + .milliseconds(250)
        var position = 100.0
        var scrobbled: [String] = []
        for _ in 0..<130 {
            at += .milliseconds(250)
            position += 0.25
            if let play = scrobbler.heard(position: position, length: 60, at: at) { scrobbled.append(play.track.id) }
        }
        #expect(scrobbled == ["a"], "30 s heard of 60, once")
    }
}

struct PremiumCounterTests {
    private let now = ContinuousClock.now

    @Test func onlyALongRunOfMissesTurnsOffAKnownPremiumAccount() {
        var counters = PremiumCounters(known: true, none: false)
        for _ in 1..<PremiumCounters.lapsedAfter { counters.recordMiss(at: now) }
        #expect(counters.status == .premium, "a run of uploads")
        counters.recordPremium()
        for _ in 1..<PremiumCounters.lapsedAfter { counters.recordMiss(at: now) }
        #expect(counters.status == .premium, "a Premium song starts the count again")

        counters.recordMiss(at: now)
        #expect(counters.status == .notPremium, "a lapsed subscription")
        #expect(counters.skipped(at: now))
        let result3 = counters.takeRecheck(at: now)
        #expect(!result3, "not due until the cool-off ends")
    }

    @Test func checksAgainInTheBackgroundAfterTakingAnAccountAsWithoutPremium() {
        var counters = PremiumCounters(known: false, none: false)
        counters.recordMiss(at: now)
        counters.recordMiss(at: now)
        #expect(!counters.skipped(at: now), "two songs say nothing yet")
        let result4 = counters.takeRecheck(at: now)
        #expect(!result4, "nothing to check while unknown")
        counters.recordMiss(at: now)
        #expect(counters.status == .notPremium)
        #expect(counters.skipped(at: now), "songs go straight to the free stream")
        let result5 = counters.takeRecheck(at: now)
        #expect(!result5, "not due yet")

        let later = now + PremiumCounters.backoff
        let result6 = counters.takeRecheck(at: later)
        #expect(result6, "due once the cool-off ends")
        let result7 = counters.takeRecheck(at: later)
        #expect(!result7, "only one check at a time")
        #expect(counters.skipped(at: later), "songs still play free meanwhile")

        counters.recordPremium()
        #expect(counters.status == .premium)
        #expect(!counters.skipped(at: later))
        counters.recordMiss(at: later)
        #expect(counters.status == .premium)
    }

    @Test func aRememberedNoPlaysFreeAndIsCheckedAtOnce() {
        var counters = PremiumCounters(known: false, none: true)
        #expect(counters.skipped(at: now), "no Premium request before the first song")
        let result8 = counters.takeRecheck(at: now)
        #expect(result8, "checked in the background straight away")
        let result9 = counters.takeRecheck(at: now)
        #expect(!result9)
    }

    @Test func repeatedErrorsPauseThePremiumPathForTheBackoff() {
        var counters = PremiumCounters(known: true, none: false)
        let result10 = counters.recordError(at: now)
        #expect(!result10)
        let result11 = counters.recordError(at: now)
        #expect(!result11)
        let result12 = counters.recordError(at: now)
        #expect(result12, "the third in a row")
        #expect(counters.skipped(at: now))
        #expect(!counters.skipped(at: now + PremiumCounters.backoff), "back after ten minutes")
        #expect(counters.status == .premium, "errors say nothing about the account")
    }
}

struct SessionSnapshotTests {
    @Test func keepsShortQueuesWholeAndLongOnesAroundTheTrack() {
        #expect(SessionSnapshot.window(count: 400, index: 350) == 0..<400)
        #expect(SessionSnapshot.window(count: 1000, index: 100) == 0..<500)
        #expect(SessionSnapshot.window(count: 1000, index: 600) == 350..<850)
        #expect(SessionSnapshot.window(count: 1000, index: 990) == 740..<1000)
    }

    @Test func savesTheWindowWithItsRecommendations() throws {
        var queue = Queue<Track>(seed: 1)
        queue.set(items: (0..<1000).map { song("\($0)") }, start: 600, shuffle: false)
        queue.insertRecommended(song("r1"), at: 601)
        queue.insertRecommended(song("r2"), at: 900)
        let snapshot = try #require(SessionSnapshot(queue, position: 12, duration: 200))
        #expect(snapshot.queue.count == 500)
        #expect(snapshot.queue[snapshot.index].id == "600")
        #expect(snapshot.recommended == [251], "r2 falls outside the window")
        #expect(SessionSnapshot(Queue<Track>(), position: 0, duration: 0) == nil, "nothing to save")
    }
}

struct PrefetcherTests {
    @Test func keepsStreamsForAnHour() {
        var prefetcher = StreamPrefetcher()
        let now = ContinuousClock.now
        prefetcher.store("a", .init(stream: FakeMusic.stream("a"), resolvedAt: now, epoch: prefetcher.epoch), at: now)
        #expect(prefetcher.has("a", at: now + .seconds(3599)))
        #expect(!prefetcher.has("a", at: now + .seconds(3600)), "too old to trust")
        let result13 = prefetcher.take("a", at: now + .seconds(3600))
        #expect(result13 == nil)
        #expect(!prefetcher.has("a", at: now), "taken, even when stale")
    }

    @Test func refusesAStreamAskedForBeforeAClear() {
        var prefetcher = StreamPrefetcher()
        let asked = prefetcher.epoch
        prefetcher.clear()
        prefetcher.store("a", .init(stream: FakeMusic.stream("a"), resolvedAt: .now, epoch: asked))
        #expect(!prefetcher.has("a"), "resolved for the old quality or account")
        prefetcher.store("a", .init(stream: FakeMusic.stream("a"), resolvedAt: .now, epoch: prefetcher.epoch))
        #expect(prefetcher.has("a"))
    }

    @Test func dropsAResolveCleared() async {
        var prefetcher = StreamPrefetcher()
        let task = prefetcher.begin("a") { FakeMusic.stream("a") }
        #expect(prefetcher.isPending("a"))
        prefetcher.clear()
        #expect(!prefetcher.isPending("a"))
        let cleared = prefetcher.finish("a", task)
        #expect(!cleared, "its stream is for the old quality")
        let running = prefetcher.begin("b") { FakeMusic.stream("b") }
        let handedOn = prefetcher.takePending("b")
        #expect(handedOn == running)
        let finished = prefetcher.finish("b", running)
        #expect(!finished, "whatever took it keeps it")
    }
}

struct SmartShuffleTests {
    private func queue(_ count: Int) -> Queue<Track> {
        var queue = Queue<Track>(seed: 7)
        queue.set(items: (0..<count).map { song("\($0)") }, start: 0, shuffle: false)
        return queue
    }

    @Test func asksForABatchWhenThePoolIsDry() {
        var smart = SmartShuffle()
        var queue = queue(20)
        let seed = smart.topUp(&queue, recent: [])
        #expect(seed != nil)
        #expect(smart.fetching)
        let result14 = smart.topUp(&queue, recent: [])
        #expect(result14 == nil, "one batch at a time")
        #expect(queue.recommendedIndices.isEmpty)
    }

    @Test func placesOneRecommendationAfterEveryThreeOrFourOwnSongsAhead() {
        var smart = SmartShuffle()
        var queue = queue(20)
        _ = smart.topUp(&queue, recent: ["r0"])
        let fresh = smart.receive((0..<10).map { song("r\($0)") } + [song("5")], generation: smart.generation)
        #expect(fresh)
        _ = smart.topUp(&queue, recent: ["r0"])
        let marks = queue.recommendedIndices
        #expect(marks.count >= 2)
        var own = 0
        var runs: [Int] = []
        for index in 0..<queue.count {
            if queue.isRecommended(at: index) {
                runs.append(own)
                own = 0
            } else {
                own += 1
            }
        }
        #expect(runs.allSatisfy { (3...4).contains($0) }, "the playing song counts towards the first run")
        #expect(!queue.items.contains { $0.id == "r0" }, "recently played songs are not recommended")
        #expect(queue.items.filter { $0.id == "5" }.count == 1, "nor songs already in the queue")
        let lastOwn = queue.items.lastIndex { !$0.id.hasPrefix("r") } ?? 0
        #expect(marks.allSatisfy { $0 < lastOwn }, "never after the last of the user's own")
        let ownAhead = (0..<(marks.last ?? 0)).filter { !queue.isRecommended(at: $0) }.count - 1
        #expect(ownAhead <= SmartShuffle.lookahead)
    }

    @Test func dropsABatchAskedForAnEarlierQueue() {
        var smart = SmartShuffle()
        var queue = queue(20)
        _ = smart.topUp(&queue, recent: [])
        let asked = smart.generation
        smart.reset()
        let result15 = smart.receive([song("r")], generation: asked)
        #expect(!result15)
        #expect(!smart.fetching)
    }
}

struct SongVersionTests {
    @Test func remembersLookupsAndStartsOverPastTheLimit() {
        var versions = SongVersionSwapper()
        let result16 = versions.beginLookup("v")
        #expect(result16)
        let result17 = versions.beginLookup("v")
        #expect(!result17, "under way")
        versions.found(song("s"), for: "v")
        #expect(versions.knownSong(for: "v")?.id == "s")
        for index in 0..<SongVersionSwapper.limit { _ = versions.beginLookup("p\(index)") }
        versions.found(nil, for: "p0")
        let result18 = versions.beginLookup("new")
        #expect(result18, "past the limit, the finished ones go")
        #expect(versions.knownSong(for: "v") == nil)
        let result19 = versions.beginLookup("p1")
        #expect(!result19, "pending ones stay")
    }
}
