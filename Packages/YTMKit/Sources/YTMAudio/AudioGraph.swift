import AVFoundation

/// Sample-exact gains and fades are applied to the buffers before scheduling, so one player is enough.
/// The mixer smooths every volume change over about 25 ms, so pausing and muting never click.
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

    /// Call again after the output device changes.
    func connectOutput() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        outputRate = rate > 0 ? rate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)
        // Plain nodes at a standard format: the engine has no reason to refuse.
        try? engine.connectNode(mixer, to: equaliser, fromBus: 0, toBus: 0, format: format)
        try? engine.connectNode(equaliser, to: engine.outputNode, fromBus: 0, toBus: 0, format: format)
        applyEqualiser()
    }

    /// The player must be stopped, so a change of rate leaves a short gap. False if the engine refused.
    func connectPlayer(_ format: AVAudioFormat) -> Bool {
        do {
            try engine.connectNode(player, to: mixer, fromBus: 0, toBus: 0, format: format)
        } catch {
            return false
        }
        playerFormat = format
        return true
    }

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

    /// 0 muted, 1 otherwise.
    func setLevel(_ level: Float) {
        self.level = level
        applyVolume()
    }

    func setSilenced(_ silenced: Bool) {
        self.silenced = silenced
        applyVolume()
    }

    func setEqualiser(enabled: Bool, gains: [Float]) {
        equaliserSetting = (enabled, EqualiserBands.clamped(gains))
        applyEqualiser()
    }

    func adoptSettings(of old: AudioGraph) {
        setLevel(old.level)
        setEqualiser(enabled: old.equaliserSetting.enabled, gains: old.equaliserSetting.gains)
    }

    /// The host time is nil when the device gives none.
    func renderedSample() -> (sample: Int64, hostTime: UInt64?)? {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return (time.sampleTime, nodeTime.isHostTimeValid ? nodeTime.hostTime : nil)
    }

    private func applyVolume() {
        mixer.outputVolume = silenced ? 0 : level
    }

    /// Lowers the whole signal by the bands' combined peak so they cannot push the music past full scale.
    private func applyEqualiser() {
        let gains = equaliserSetting.gains
        for (band, gain) in zip(equaliser.bands, gains) {
            band.gain = gain
        }
        equaliser.bypass = !equaliserSetting.enabled || gains.allSatisfy { $0 == 0 }
        equaliser.globalGain = -EqualiserBands.headroom(for: gains, sampleRate: outputRate)
    }
}
