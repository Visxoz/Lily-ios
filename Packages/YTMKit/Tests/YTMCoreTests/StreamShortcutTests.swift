import Foundation
import Testing
@testable import YTMCore

/// The requests a play saves: tracking reused from the Premium answer, the saved player script at
/// launch, and free clients that fail kept from going first.
@Suite struct StreamShortcutTests {
    private let now = ContinuousClock.now

    // MARK: - Free clients

    @Test func clientsThatFailedGoAfterTheRest() {
        let names = { (cut: [String], failed: [String: ContinuousClock.Instant]) in
            StreamResolver.clients(cut: cut, failed: failed, at: now).map(\.name)
        }
        #expect(names([], [:]) == ["VISIONOS", "ANDROID_VR", "IOS"])
        #expect(names([], ["VISIONOS": now]) == ["ANDROID_VR", "IOS", "VISIONOS"])
        #expect(
            names([], ["ANDROID_VR": now, "VISIONOS": now - .seconds(60)]) == ["IOS", "VISIONOS", "ANDROID_VR"],
            "failed longest ago first"
        )
        #expect(names([], ["VISIONOS": now - StreamResolver.demotedFor]) == ["VISIONOS", "ANDROID_VR", "IOS"], "for a while only")
        #expect(names(["IOS"], ["VISIONOS": now]) == ["ANDROID_VR", "VISIONOS", "IOS"], "cut-off clients stay last")
    }

    @Test func aPassDemotesTheClientsBeforeTheOneThatPlayed() {
        var failed = ["IOS": now - StreamResolver.demotedFor, "ANDROID_VR": now - .seconds(60)]
        StreamResolver.record(&failed, failing: ["VISIONOS"], played: "ANDROID_VR", at: now)
        #expect(failed == ["VISIONOS": now], "the one that played is not demoted, and old failures go")
    }

    // MARK: - Play tracking

    private func player(_ base: String = "https://s.youtube.com/api/stats/playback?ns=yt") throws -> JSON {
        try JSON(data: Data(#"{"streamingData":{},"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"\#(base)"}}}"#.utf8))
    }

    private func base(_ player: JSON?) -> String? {
        player?["playbackTracking", "videostatsPlaybackUrl", "baseUrl"].string
    }

    @Test func trackingIsTakenOnceForTheSameAccount() throws {
        var kept = PlayTrackings()
        kept.keep(try player(), videoId: "a", login: 1, at: now)
        let taken = kept.take(videoId: "a", login: 1, at: now + .seconds(5))
        #expect(base(taken) == "https://s.youtube.com/api/stats/playback?ns=yt")
        #expect(taken?["streamingData"].exists == false, "only the tracking is kept")
        #expect(kept.take(videoId: "a", login: 1, at: now) == nil, "a repeat asks again")
    }

    @Test func trackingIsRefusedForAnotherAccountOrOnceStale() throws {
        var kept = PlayTrackings()
        kept.keep(try player(), videoId: "a", login: 1, at: now)
        #expect(kept.take(videoId: "a", login: 2, at: now) == nil)
        kept.keep(try player(), videoId: "e", login: 1, at: now)
        #expect(kept.take(videoId: "e", login: nil, at: now) == nil)
        kept.keep(try player(), videoId: "b", login: 1, at: now)
        #expect(kept.take(videoId: "b", login: 1, at: now + PlayTrackings.freshFor) == nil)
        kept.keep(try player(), videoId: "c", login: nil, at: now)
        #expect(kept.take(videoId: "c", login: nil, at: now) == nil, "signed out keeps nothing")
        kept.keep(try JSON(data: Data(#"{"playbackTracking":{"videostatsWatchtimeUrl":{"baseUrl":"x"}}}"#.utf8)), videoId: "d", login: 1, at: now)
        #expect(kept.take(videoId: "d", login: 1, at: now) == nil, "no stats URL, so reportPlay asks itself")
        let signedOut = #"{"responseContext":{"serviceTrackingParams":[{"params":[{"key":"logged_in","value":"0"}]}]},"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"x"}}}"#
        kept.keep(try JSON(data: Data(signedOut.utf8)), videoId: "f", login: 1, at: now)
        #expect(kept.take(videoId: "f", login: 1, at: now) == nil, "answered as signed out")
    }

    @Test func trackingKeepsOnlySoMany() throws {
        var kept = PlayTrackings()
        for n in 0...PlayTrackings.limit {
            kept.keep(try player(), videoId: "\(n)", login: 1, at: now + .milliseconds(n))
        }
        #expect(kept.take(videoId: "0", login: 1, at: now) == nil, "the oldest goes")
        #expect(kept.take(videoId: "\(PlayTrackings.limit)", login: 1, at: now) != nil)
    }

    // MARK: - Player script

    private func store() -> FileStore {
        FileStore(directory: .temporaryDirectory.appending(path: "ytm-player-\(UUID().uuidString)"))
    }

    @Test func launchPlaysTheSavedScriptWhileYouTubesIsChecked() async throws {
        let store = store()
        store.save(PlayerScript(id: "0000abcd", signatureTimestamp: 20000, code: ""), to: .player)
        let (asked, ask) = AsyncStream.makeStream(of: Void.self)
        let scripts = PlayerScripts { _, _ in
            ask.yield()
            throw YTMError(.parse, "offline")
        }
        #expect(try await scripts.player(store: store).id == "0000abcd")
        var checks = asked.makeAsyncIterator()
        _ = await checks.next()
        #expect(try await scripts.player(store: store).id == "0000abcd", "kept while the check runs or once it fails")
    }

    @Test func withoutASavedScriptLaunchWaitsForYouTubes() async throws {
        let scripts = PlayerScripts { _, _ in throw YTMError(.parse, "offline") }
        let store = store()
        await #expect(throws: YTMError.self) { try await scripts.player(store: store) }
        await #expect(throws: YTMError.playerUnprepared) { try await scripts.player(store: store) }
    }
}
