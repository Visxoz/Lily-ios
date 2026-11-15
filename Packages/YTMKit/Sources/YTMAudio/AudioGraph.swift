import AVFoundation

/// The engine's nodes: one player, into a mixer that carries the mute and
/// pause ramps and converts each item's rate to the output's, into
/// the equaliser, and out. Gains and fades that must land on a given sample,
/// normalisation and crossfades, are applied to the buffers before they are
/// scheduled, so one player is all the graph needs. The mixer smooths every
/// change of its volume over about 25 ms, so neither pausing nor muting
/// ever clicks.
final class AudioGraph {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private let equaliser = AVAudioUnitEQ(numberOfBands: EqualiserBands.frequencies.count)
    private(set) var playerFormat: AVAudioFormat?
    private var outputRate = 48_000.0
    private var level: Float = 1
    private var silenced = false
    private var equaliserSetting: (enabled: Bool, gains: [Float]) = (false, [])

    /// Renders into `offlineFormat` on demand rather than to the device, for tests.
    init(offlineFormat: AVAudioFormat? = nil) {
        if let offlineFormat {
            try? engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4_096)
        }
        for node in [player, mixer, equaliser] {
            engine.attach(node)
        }
        for (band, frequency) in zip(equaliser.bands, EqualiserBands.frequencies) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = EqualiserBands.bandwidth
            band.gain = 0
            band.bypass = false
        }
        connectOutput()
    }

    /// Connects the mixer onwards at the output's current format, as after
    /// the output device changes.
    func connectOutput() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        outputRate = rate > 0 ? rate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)
        // Plain nodes at a standard format: the engine has no reason to refuse.
        try? engine.connectNode(mixer, to: equaliser, fromBus: 0, toBus: 0, format: format)
        try? engine.connectNode(equaliser, to: engine.outputNode, fromBus: 0, toBus: 0, format: format)
        applyEqualiser()
    }

    /// Connects the stopped player at the rate of the item's buffers, so a
    /// change of rate leaves a short gap. False if the engine refused.
    func connectPlayer(_ format: AVAudioFormat) -> Bool {
        do {
            try engine.connectNode(player, to: mixer, fromBus: 0, toBus: 0, format: format)
        } catch {
            return false
        }
        playerFormat = format
        return true
    }

    /// Starts the engine if it is not running; false if it would not.
    func start() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// The output's level as a factor: 0 muted, 1 otherwise.
    func setLevel(_ level: Float) {
        self.level = level
        applyVolume()
    }

    /// Silences the output, ramping down, for a pause.
    func setSilenced(_ silenced: Bool) {
        self.silenced = silenced
        applyVolume()
    }

    func setEqualiser(enabled: Bool, gains: [Float]) {
        equaliserSetting = (enabled, EqualiserBands.clamped(gains))
        applyEqualiser()
    }

    /// Takes on `old`'s mute and equaliser, as a graph made in its place.
    func adoptSettings(of old: AudioGraph) {
        setLevel(old.level)
        setEqualiser(enabled: old.equaliserSetting.enabled, gains: old.equaliserSetting.gains)
    }

    /// The player's sample being rendered, and the host time it renders at
    /// when the device gives one.
    func renderedSample() -> (sample: Int64, hostTime: UInt64?)? {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return (time.sampleTime, nodeTime.isHostTimeValid ? nodeTime.hostTime : nil)
    }

    private func applyVolume() {
        mixer.outputVolume = silenced ? 0 : level
    }

    /// Sets each band, and lowers the whole signal by the bands' combined
    /// peak so they cannot push the music past full scale.
    private func applyEqualiser() {
        let gains = equaliserSetting.gains
        for (band, gain) in zip(equaliser.bands, gains) {
            band.gain = gain
        }
        equaliser.bypass = !equaliserSetting.enabled || gains.allSatisfy { $0 == 0 }
        equaliser.globalGain = -EqualiserBands.headroom(for: gains, sampleRate: outputRate)
    }
}
