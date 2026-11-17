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
        _ = connect(mixer, to: equaliser, format: format)
        _ = connect(equaliser, to: engine.outputNode, format: format)
        applyEqualiser()
    }

    /// The player must be stopped, so a change of rate leaves a short gap. False if the engine refused.
    func connectPlayer(_ format: AVAudioFormat) -> Bool {
        guard connect(player, to: mixer, format: format) else { return false }
        playerFormat = format
        return true
    }

    /// iOS 26 has only the raising form. It is safe with what arrives here, standard float stereo at a
    /// positive rate, but raises if anything other than a mixer input changes while the engine runs.
    private func connect(_ node: AVAudioNode, to next: AVAudioNode, format: AVAudioFormat?) -> Bool {
        guard #available(iOS 27, *) else {
            // After a device change the engine may already have been restarted; the seek that follows starts it again.
            if engine.isRunning, !(next is AVAudioMixerNode) { engine.stop() }
            engine.connect(node, to: next, fromBus: 0, toBus: 0, format: format)
            return true
        }
        return (try? engine.connectNode(node, to: next, fromBus: 0, toBus: 0, format: format)) != nil
    }

    /// False if the player refused. On iOS 26, play() raises unless the player is connected and the
    /// engine running; the engine can stop between `start` and here when the system takes the output.
    func play() -> Bool {
        guard #available(iOS 27, *) else {
            guard engine.isRunning else { return false }
            player.play()
            return true
        }
        return (try? player.playAudio()) != nil
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
