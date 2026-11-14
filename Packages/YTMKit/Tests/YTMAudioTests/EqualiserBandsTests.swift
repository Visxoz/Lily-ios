import Testing
@testable import YTMAudio

struct EqualiserBandsTests {
    @Test func matchesYtmNative() {
        #expect(EqualiserBands.frequencies == [60, 150, 400, 1_000, 2_400, 15_000])
        #expect(EqualiserBands.maxGain == 12)
        #expect(EqualiserBands.presets.map(\.name) == ["Flat", "Bass boost", "Treble boost", "Vocal", "Rock", "Electronic", "Acoustic"])
        #expect(EqualiserBands.presets[3].gains == [-2, -1, 2, 4, 3, 0])
        #expect(abs(EqualiserBands.bandwidth - 1.53) < 0.01, "Q 0.9, about an octave and a half")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func bandsReachTheirGain(rate: Double) {
        for gain: Float in [-12, 6] {
            for (band, centre) in EqualiserBands.frequencies.enumerated() {
                let peak = EqualiserBands.Peak(band: band, gain: gain, rate: rate)
                #expect(abs(peak.response(at: Double(centre), rate: rate) - Double(gain)) < 0.01)
            }
            let middle = EqualiserBands.Peak(band: 3, gain: gain, rate: rate)
            #expect(abs(middle.response(at: 20, rate: rate)) < 0.1, "far bands untouched")
            #expect(abs(middle.response(at: 20_000, rate: rate)) < 0.1)
        }
    }

    @Test func leavesHeadroomForBoosts() {
        #expect(EqualiserBands.headroom(for: [0, 0, 0, 0, 0, 0], sampleRate: 48_000) == 0)
        #expect(EqualiserBands.headroom(for: [-6, -6, -6, -6, -6, -6], sampleRate: 48_000) == 0)
        // Clamped to 12 dB, and overlapping boosts add up past any one band.
        #expect(abs(EqualiserBands.headroom(for: [20, 0, 0, 0, 0, 0], sampleRate: 48_000) - 12) < 0.1)
        #expect(EqualiserBands.headroom(for: [12, 12, 12, 12, 12, 12], sampleRate: 48_000) > 12)
        let bass = EqualiserBands.presets[1].gains
        #expect(EqualiserBands.headroom(for: bass, sampleRate: 48_000) >= 6)
    }

    @Test func bandsPastNyquistPassThrough() {
        let peak = EqualiserBands.Peak(band: 5, gain: 12, rate: 22_050)
        #expect(peak.response(at: 1_000, rate: 22_050) == 0)
        #expect(EqualiserBands.clamped([30, -30]) == [12, -12, 0, 0, 0, 0])
    }
}
