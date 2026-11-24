import Foundation
import Testing
@testable import YTMPlayback

@MainActor
struct SleepTimerTests {
    @Test func endOfSongStopsOnTheSongInsteadOfMovingOn() async {
        let rig = await playing("a", "b")
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next != nil)

        rig.player.setSleepTimer(.endOfSong)
        #expect(rig.audio.next == nil, "the song queued after it is dropped")
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next == nil, "and nothing queued in its place")

        rig.player.handle(.finished)
        await rig.settle()
        #expect(rig.player.current?.id == "a")
        #expect(!rig.player.isPlaying)
        #expect(rig.player.sleepTimer == nil)
    }

    @Test func turnedOffNearTheEndTheNextSongStillQueues() async {
        let rig = await playing("a", "b")
        rig.player.setSleepTimer(.endOfSong)
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next == nil)

        rig.player.setSleepTimer(nil)
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
    }

    @Test func timedPausesOnceItIsDue() async {
        let rig = await playing("a")
        rig.player.setSleepTimer(.at(.now))
        await rig.player.sleepWait?.value
        #expect(!rig.player.isPlaying)
        #expect(rig.player.sleepTimer == nil)
    }

    @Test func wakingLateLeavesAPlaySinceAlone() async {
        let rig = await playing("a")
        rig.player.setSleepTimer(.at(.now.addingTimeInterval(-60)))
        await rig.player.sleepWait?.value
        #expect(rig.player.isPlaying)
        #expect(rig.player.sleepTimer == nil)
    }

    @Test func turningOffCancelsTheWait() async {
        let rig = await playing("a")
        rig.player.setSleepTimer(.at(.now))
        let wait = rig.player.sleepWait
        rig.player.setSleepTimer(nil)
        await wait?.value
        #expect(rig.player.isPlaying)
    }

    private func playing(_ ids: String...) async -> Rig {
        let rig = await started()
        rig.player.play(ids.map { song($0) })
        await rig.settle()
        await rig.soundStarts()
        return rig
    }
}
