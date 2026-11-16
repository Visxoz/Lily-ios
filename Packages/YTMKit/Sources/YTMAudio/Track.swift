import AVFoundation

final class Track {
    let item: AudioItem
    let loudnessGain: Float
    /// The normalisation gain its last buffer ended on, so a setting change ramps from there.
    var gain: Float?
    let loader: StreamLoader
    /// `play` started it, so its first sound is announced as `started`.
    let announcesStart: Bool
    var download: Task<Void, Never>?
    private(set) var isCancelled = false
    private(set) var source: (any PacketSource)?
    private(set) var decoder: PacketDecoder?
    /// Stereo, at its own rate.
    private(set) var bufferFormat: AVAudioFormat?
    private(set) var failure: AudioFailure?
    /// Its last frame has been decoded, or it failed.
    private(set) var finished = false
    /// A buffer of its sound has been scheduled.
    var hasSounded = false
    private(set) var leadTrimmed = false
    private var startAt: Double
    /// The file's first bytes, until there are enough to tell its container.
    private var head = Data()
    private var parsed: Int64 = 0

    init(item: AudioItem, loader: StreamLoader, startAt: Double, announcesStart: Bool) {
        self.item = item
        loudnessGain = item.loudnessGain
        self.loader = loader
        self.startAt = startAt
        self.announcesStart = announcesStart
    }

    var sampleRate: Double? { decoder?.sampleRate }
    var position: Int64 { decoder?.position ?? 0 }

    /// The item's length in frames, once its file is complete.
    var length: Int64? { decoder?.length(of: state) }

    /// Its length in seconds: exact once its file is complete, else as its container states.
    var duration: Double? {
        guard let rate = sampleRate, let length else { return source?.format?.duration }
        return Double(length) / rate
    }

    var bufferedFraction: Double {
        loader.isComplete ? 1 : loader.total > 0 ? Double(loader.available) / Double(loader.total) : 0
    }

    func cancel() {
        isCancelled = true
        download?.cancel()
        download = nil
    }

    /// With no decoder yet nothing more can play; with one, it plays what it has and ends.
    func fail(_ failure: AudioFailure) {
        if self.failure == nil {
            self.failure = failure
        }
        if decoder == nil {
            finished = true
        }
    }

    func receive(_ data: Data) {
        guard failure == nil else { return }
        do {
            var bytes = data
            if source == nil {
                head.append(data)
                guard head.count >= PacketSources.sniffLength else { return }
                source = try head.withUnsafeBytes(PacketSources.make)
                bytes = head
                head = Data()
            }
            try bytes.withUnsafeBytes { try source?.parse($0) }
            parsed += Int64(bytes.count)
            if decoder == nil, let format = source?.format {
                let decoder = try PacketDecoder(source: format, file: loader.reader)
                decoder.seek(to: Int64((startAt * format.sampleRate).rounded()))
                bufferFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)
                self.decoder = decoder
            }
        } catch {
            fail(error as? AudioFailure ?? .damaged)
        }
    }

    /// Starts again at `seconds`, or there once the decoder opens.
    func seek(to seconds: Double) {
        finished = false
        guard let decoder else {
            startAt = seconds
            return
        }
        decoder.seek(to: Int64((seconds * decoder.sampleRate).rounded()))
    }

    /// A failed download ends the item where its bytes ran out.
    func supply() -> PacketDecoder.Supply {
        guard let decoder, !finished else { return .ended }
        do {
            let supply = try decoder.supply(state)
            if supply == .ended || (supply == .waiting && failure != nil) {
                finished = true
                return .ended
            }
            return supply
        } catch {
            fail(error as? AudioFailure ?? .damaged)
            finished = true
            return .ended
        }
    }

    var channels: Crossfade.Channels? {
        decoder.map { ($0.samples(0), $0.samples(1)) }
    }

    /// Cut so a crossfade brings in music rather than silence. False while waiting on the file.
    func trimLeadingSilence(limit: Int64) -> Bool {
        guard !leadTrimmed else { return true }
        guard let decoder else { return false }
        scan: while decoder.position < limit {
            switch supply() {
            case .waiting:
                return false
            case .ended:
                break scan
            case .frames(let count):
                let window = min(count, Int(limit - decoder.position))
                guard let channels else { break scan }
                let silent = Crossfade.leadingSilence(channels, count: window)
                decoder.consume(silent)
                if silent < window {
                    break scan
                }
            }
        }
        leadTrimmed = true
        return true
    }

    /// Cuts at most `limit` frames, so a long quiet passage or hidden track is not mistaken
    /// for the end. Nil until the file is complete.
    func soundEnd(limit: Int64) -> Int64? {
        guard let length, let format = source?.format else { return nil }
        let from = max(length - limit, 0)
        guard let scanner = try? PacketDecoder(source: format, file: loader.reader) else { return length }
        scanner.seek(to: from)
        var end = from
        while case .frames(let count) = (try? scanner.supply(state)) ?? .ended {
            let found = Crossfade.soundEnd((scanner.samples(0), scanner.samples(1)), count: count)
            if found > 0 {
                end = scanner.position + Int64(found)
            }
            scanner.consume(count)
        }
        return end
    }

    /// Complete once every byte has been both downloaded and read by the container.
    private var state: PacketDecoder.SourceState {
        PacketDecoder.SourceState(
            packets: source?.packets ?? PacketIndex(),
            available: loader.available,
            complete: loader.isComplete && parsed >= loader.total,
            trailingFrames: source?.trailingFrames ?? 0
        )
    }
}
