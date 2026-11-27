import Foundation
import Testing
@testable import YTMAudio

private let rate = 48_000.0
private let reach = Varispeed.reach

/// A sine at `hz`, the right side inverted.
private func sine(_ hz: Double, _ frames: Int) -> (left: [Float], right: [Float]) {
    let left = (0..<frames).map { Float(sin(2 * Double.pi * hz * Double($0) / rate)) * 0.5 }
    return (left, left.map { -$0 })
}

struct VarispeedTests {
    @Test(arguments: [1 - Varispeed.most, 1 + Varispeed.most])
    func readsASineAtTheSpeedsAsked(speed: Double) {
        let input = sine(1_000, 96_000)
        let curve = Varispeed(ramp: 24_000, speed: speed)
        // From `reach` before 1,000, which pass as they are, so the curve starts at 1,000.
        let out = curve.read(input, from: 1_000 - reach, frames: reach + 48_000)
        #expect(out.left.count == reach + 48_000)
        let parts = curve.read(input, from: 1_000 - reach, frames: reach + 48_000, piece: 1_000, take: 777)
        #expect(parts == out, "in parts as in one")
        #expect(out.left.prefix(reach) == input.left[(1_000 - reach)..<1_000])
        #expect(out.right == out.left.map { -$0 }, "channels kept apart")
        let error = (0..<48_000).map { t in
            let at = 1_000 + curve.songFrames(Double(t))
            return abs(out.left[reach + t] - Float(sin(2 * Double.pi * 1_000 * at / rate)) * 0.5)
        }
        #expect((error.max() ?? 1) < 2e-3)
    }

    @Test func playsOnUnchangedAtSpeed() {
        // Below the cutoff, so the passband passes it as it is.
        let input = sine(5_000, 4_800)
        let out = Varispeed(ramp: 1, speed: 1).read(input, from: 0, frames: 4_800)
        // Short of the last 16, well clear of the 8 whose taps reach past the end; there is no such edge at the start.
        let error = (0..<4_784).map { max(abs(out.left[$0] - input.left[$0]), abs(out.right[$0] - input.right[$0])) }
        #expect((error.max() ?? 1) < 2e-3)
    }

    @Test func readsSilencePastTheEndUntilNoTapReachesIt() {
        let curve = Varispeed(ramp: 1, speed: 1)
        let read = { (input: [Float]) in curve.read((input, input), from: 0, frames: 30).left }
        let out = read(Array(repeating: 0.5, count: 8))
        // As if zeros lay after it, until no tap reaches it.
        let padded = read(Array(repeating: 0.5, count: 8) + Array(repeating: 0, count: 8))
        #expect(out.count == 8 + reach, "past the end by its taps")
        #expect(padded.prefix(out.count) == out[...])
        #expect(padded[out.count...].allSatisfy { $0 == 0 })
        #expect(out.prefix(reach).allSatisfy { $0 == 0.5 }, "the first as they are")
    }

    @Test func keepsSongTimeThroughARampAndAfter() {
        let curve = Varispeed(ramp: 48_000, speed: 1.04)
        // Half way up the ramp, at 1.01 on average.
        #expect(abs(curve.songFrames(24_000) - 24_000 * 1.01) < 1e-6)
        #expect(abs(curve.songFrames(48_000) - 48_000 * 1.02) < 1e-6, "a second at 1.02")
        // Held past the ramp, it runs at the speed reached.
        #expect(abs(curve.songFrames(96_000) - 48_000 * (1.02 + 1.04)) < 1e-6)
    }
}
