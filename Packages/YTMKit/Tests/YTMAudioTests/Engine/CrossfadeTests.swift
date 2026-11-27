import Foundation
import Testing
@testable import YTMAudio

struct CrossfadeTests {
    private func crossfaded(_ incoming: [Float]?, _ outgoing: [Float]?, gains: (Float, Float) = (1, 1)) -> [Float] {
        let length = incoming?.count ?? outgoing?.count ?? 0
        let mixer = Automix.Mixer(frames: length, style: .crossfade, rate: 48_000)
        let out = mixer.mixed(incoming.map(StereoBuffer.init), outgoing.map(StereoBuffer.init), gains: gains)
        #expect(out.left == out.right, "channels fade together")
        return out.left
    }

    @Test func fadesWithEqualPower() {
        let samples = crossfaded(Array(repeating: 1, count: 1_000), Array(repeating: 1, count: 1_000))
        #expect(samples[0] == 1, "starts on the outgoing item alone")
        let angle = 0.5 * Double.pi / 2
        // Uncorrelated tracks sum by power, so the curves' squares sum to 1.
        #expect(abs(samples[500] - Float(sin(angle) + cos(angle))) < 1e-6)
        #expect(samples[999] > 0.99 && samples[999] < 1.01, "ends near the incoming item alone")
    }

    @Test func fadesOutOverSilenceOnceTheIncomingItemEnds() {
        let samples = crossfaded(nil, Array(repeating: 0.5, count: 4), gains: (1, 2))
        #expect(samples[0] == 1, "the outgoing item at its own gain")
        #expect(samples[3] < samples[0])
    }

    @Test func hearsSilenceBelowTheThresholdOnly() {
        let quiet = StereoBuffer([0, -0.000_5, 0, 0.01, 0, 0])
        withExtendedLifetime(quiet) {
            #expect(Crossfade.isSilent(quiet.channels, at: 1))
            #expect(!Crossfade.isSilent(quiet.channels, at: 3))
            #expect(Crossfade.leadingSilence(quiet.channels, count: 6) == 3)
            #expect(Crossfade.soundEnd(quiet.channels, count: 6) == 4)
            #expect(Crossfade.soundEnd(quiet.channels, count: 3) == 0)
        }
    }

    @Test func glidesFromOneGainToAnotherAcrossPieces() {
        let ones = StereoBuffer(Array(repeating: 1, count: 4))
        let out = StereoBuffer(Array(repeating: 0, count: 4))
        let ramp = Crossfade.Ramp(from: 1, to: 0.5, length: 4)
        withExtendedLifetime(ones) {
            Crossfade.copy(ones.channels, gain: ramp, count: 2, into: out.output, at: 0)
            Crossfade.copy(ones.channels, gain: ramp, count: 2, into: out.output, at: 2)
        }
        #expect(out.samples.left == [1, 0.875, 0.75, 0.625] && out.samples.right == out.samples.left)
        #expect(ramp.at(4) == 0.5, "where the next buffer starts")
    }

    @Test func fadesInFromSilence() {
        let buffer = StereoBuffer(Array(repeating: 1, count: 8))
        Crossfade.fadeIn(buffer.output, count: 8, over: 4)
        #expect(buffer.samples.left == [0.25, 0.5, 0.75, 1, 1, 1, 1, 1])
        #expect(buffer.samples.right == buffer.samples.left)
    }
}
