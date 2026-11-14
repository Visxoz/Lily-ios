import Foundation

/// The equaliser's six peaking bands and starting points, as ytm-native's `eq.rs`.
public struct EqualiserBands {
    /// Each band's centre in Hz.
    public static let frequencies: [Float] = [60, 150, 400, 1_000, 2_400, 15_000]
    /// The furthest a band goes either way, in dB.
    public static let maxGain: Float = 12
    /// Each band's gain in dB, from low to high.
    public static let presets: [(name: String, gains: [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0]),
        ("Bass boost", [6, 4, 1, 0, 0, 0]),
        ("Treble boost", [0, 0, 0, 1, 4, 6]),
        ("Vocal", [-2, -1, 2, 4, 3, 0]),
        ("Rock", [4, 2, -2, -1, 2, 4]),
        ("Electronic", [5, 3, 0, -1, 2, 4]),
        ("Acoustic", [3, 2, 1, 1, 2, 2]),
    ]

    /// How wide the peaks are: Q 0.9, about an octave and a half.
    static let q = 0.9
    /// The same width as `AVAudioUnitEQ` takes it, in octaves.
    static let bandwidth = Float(2 / log(2.0) * asinh(1 / (2 * q)))

    /// Every band's gain within range, one per band.
    static func clamped(_ gains: [Float]) -> [Float] {
        frequencies.indices.map { gains.indices.contains($0) ? min(max(gains[$0], -maxGain), maxGain) : 0 }
    }

    /// How far the bands together lift the loudest frequency, in dB, so the
    /// whole signal can be lowered by as much and never clip. Neighbouring
    /// bands overlap and their boosts add, so the peak is found on a
    /// sixth-octave grid from 20 Hz to below Nyquist, as `eq.rs` does.
    static func headroom(for gains: [Float], sampleRate: Double) -> Float {
        let filters = clamped(gains).enumerated().map { Peak(band: $0.offset, gain: $0.element, rate: sampleRate) }
        let top = sampleRate * 0.45
        let peak = (0..<64)
            .map { min(20 * pow(1_000, Double($0) / 63), top) }
            .map { hz in filters.reduce(0) { $0 + $1.response(at: hz, rate: sampleRate) } }
            .max() ?? 0
        return Float(max(peak, 0))
    }

    /// One band's peaking filter, from RBJ's Audio EQ Cookbook, kept only to
    /// work out the bands' combined response. A peaking filter's b1 equals its a1.
    struct Peak {
        var b0 = 1.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

        init(band: Int, gain: Float, rate: Double) {
            let centre = Double(EqualiserBands.frequencies[band])
            // A centre at or past Nyquist would be unstable, so it passes through.
            guard centre < rate * 0.45 else { return }
            let a = pow(10, Double(gain) / 40)
            let w0 = 2 * Double.pi * centre / rate
            let alpha = sin(w0) / (2 * EqualiserBands.q)
            let a0 = 1 + alpha / a
            b0 = (1 + alpha * a) / a0
            b2 = (1 - alpha * a) / a0
            a1 = -2 * cos(w0) / a0
            a2 = (1 - alpha / a) / a0
        }

        /// The filter's gain in dB at `hz`, from its transfer function.
        func response(at hz: Double, rate: Double) -> Double {
            let w = 2 * Double.pi * hz / rate
            func magnitude(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
                let im = -c1 * sin(w) - c2 * sin(2 * w)
                return (re * re + im * im).squareRoot()
            }
            return 20 * log10(magnitude(b0, a1, b2) / magnitude(1, a1, a2))
        }
    }
}
