import AVFoundation

/// Decodes a source's packets, read from the cache file, to Float32 with
/// the codec's padding cut at both ends, so an item's first frame is the
/// music's first and its last the music's last, and gapless joins are exact.
/// One decoder serves every codec AudioToolbox has: Opus and AAC alike.
final class PacketDecoder {
    enum Supply: Equatable {
        /// Frames ready to take, at least one.
        case frames(Int)
        /// More of the file has to arrive first.
        case waiting
        case ended
    }

    /// What the decoder needs to know of the item's file as it arrives.
    struct SourceState {
        var packets: PacketIndex
        /// Bytes of the file on disk.
        var available: Int64
        /// No more packets will come, so the end's padding is known.
        var complete: Bool
        var trailingFrames: Int64
    }

    let format: AVAudioFormat
    /// The item frame of the next frame to take.
    private(set) var position: Int64 = 0

    /// Opus is decoded from 80 ms before a seek's target, as a fresh decoder
    /// takes this long to settle (RFC 7845's recommended pre-roll).
    private static let opusPreRoll: Int64 = 3_840
    /// AudioToolbox's Opus decoder drops the 2.5 ms of overlap at its start
    /// that libopus leaves to the pre-skip, so it runs this far ahead of the
    /// codec's own timeline. `PacketDecoderTests` holds it to that.
    static let opusDecoderDelay: Int64 = 120
    private static let outputCapacity: AVAudioFrameCount = 8_192
    private static let inputPackets: AVAudioPacketCount = 64

    /// A fresh one for every seek: AudioToolbox's Opus decoder drops its
    /// first 2.5 ms only when new, not after a reset.
    private var converter: AVAudioConverter
    private var converterUsed = false
    private let cookie: Data?
    private let inputFormat: AVAudioFormat
    private var input: AVAudioCompressedBuffer
    private let output: AVAudioPCMBuffer
    private let channels: UnsafePointer<UnsafeMutablePointer<Float>>
    private let file: FileHandle
    /// Decoded frames before the item's first: the codec's leading frames,
    /// less what AudioToolbox drops itself.
    private let itemOffset: Int64
    private let preRoll: Int64
    private let leadingFrames: Int64
    private var nextPacket = 0
    /// The decoded frame the converter gives next, counted from the file's
    /// first packet, less what AudioToolbox drops.
    private var outputFrame: Int64 = 0
    private var dropBefore: Int64 = 0
    /// A seek to decoded frame `target`, from `from`, waiting for its packet to be listed.
    private var seeking: (target: Int64, from: Int64)?
    /// The frames of `output` ready to take.
    private var carry = 0..<0
    private var ended = false
    private var failures = 0

    init(source format: SourceFormat, file: FileHandle) throws {
        var description = format.description
        guard let inputFormat = AVAudioFormat(streamDescription: &description),
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate,
                  channels: min(description.mChannelsPerFrame, 2),
                  interleaved: false
              ),
              let converter = Self.converter(from: inputFormat, to: outputFormat, cookie: format.cookie),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: Self.outputCapacity),
              let channels = output.floatChannelData
        else { throw AudioFailure.unsupported }
        self.inputFormat = inputFormat
        self.format = outputFormat
        self.converter = converter
        cookie = format.cookie
        self.output = output
        self.channels = UnsafePointer(channels)
        self.file = file
        input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: Self.inputPackets, maximumPacketSize: 1_536)
        let delay = format.isOpus ? Self.opusDecoderDelay : 0
        leadingFrames = format.leadingFrames
        itemOffset = max(format.leadingFrames - delay, 0)
        preRoll = format.isOpus ? Self.opusPreRoll : 2 * Int64(description.mFramesPerPacket)
        seek(to: 0)
    }

    private static func converter(from input: AVAudioFormat, to output: AVAudioFormat, cookie: Data?) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: input, to: output)
        converter?.magicCookie = cookie
        converter?.downmix = input.channelCount > output.channelCount
        return converter
    }

    /// Starts the codec afresh at packet `packet`, which starts on decoded frame `start`.
    private func restart(at packet: Int, frame start: Int64) throws {
        if converterUsed {
            guard let fresh = Self.converter(from: inputFormat, to: format, cookie: cookie) else { throw AudioFailure.unsupported }
            converter = fresh
            converterUsed = false
        }
        nextPacket = packet
        outputFrame = start
    }

    var sampleRate: Double { format.sampleRate }
    var channelCount: Int { Int(format.channelCount) }

    /// The item's length in frames, once every packet is listed.
    func length(of state: SourceState) -> Int64? {
        state.complete ? max(state.packets.frames - leadingFrames - state.trailingFrames, 0) : nil
    }

    /// Starts decoding at item frame `frame`, exactly: from the packet
    /// before it, with a pre-roll, dropping the frames ahead of it.
    func seek(to frame: Int64) {
        let target = max(frame, 0) + itemOffset
        seeking = (target, max(target - preRoll, 0))
        position = max(frame, 0)
        carry = 0..<0
        ended = false
    }

    /// The samples of channel `channel` ready to take, valid until the next call.
    func samples(_ channel: Int) -> UnsafePointer<Float> {
        UnsafePointer(channels[min(channel, channelCount - 1)] + carry.lowerBound)
    }

    func consume(_ count: Int) {
        carry = carry.lowerBound + count..<carry.upperBound
        position += Int64(count)
    }

    /// The frames ready to take, decoding more of the file as needed.
    func supply(_ state: SourceState) throws -> Supply {
        if !carry.isEmpty {
            return .frames(carry.count)
        }
        if ended {
            return .ended
        }
        if let seeking {
            guard let (packet, start) = state.packets.packet(holding: seeking.from) else {
                guard state.complete else { return .waiting }
                ended = true
                return .ended
            }
            try restart(at: packet, frame: start)
            dropBefore = seeking.target
            self.seeking = nil
        }
        let end = length(of: state).map { $0 + itemOffset } ?? .max
        while true {
            var error: NSError?
            converterUsed = true
            let status = converter.convert(to: output, error: &error) { [unowned self] _, status in
                nextBuffer(state, status: status)
            }
            if status == .error {
                try recover(state)
                continue
            }
            failures = 0
            let first = outputFrame
            let count = Int64(output.frameLength)
            outputFrame += count
            let start = max(first, dropBefore)
            let stop = min(first + count, end)
            if stop > start {
                carry = Int(start - first)..<Int(stop - first)
                position = start - itemOffset
                return .frames(carry.count)
            }
            if status == .endOfStream || first + count >= end {
                ended = true
                return .ended
            }
            if count == 0 {
                return .waiting
            }
        }
    }

    /// Skips a batch the codec could not decode, as one bad packet should
    /// not end the song; several in a row mean the file is broken.
    private func recover(_ state: SourceState) throws {
        failures += 1
        guard failures <= 3 else { throw AudioFailure.damaged }
        try restart(at: nextPacket, frame: state.packets.start(of: nextPacket))
    }

    /// The next packets for the converter, read from the file in one go.
    private func nextBuffer(_ source: SourceState, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let packets = source.packets
        // The last packet listed waits for the next or for the end, as only
        // then is its padding known.
        let usable = source.complete ? packets.count : packets.count - 1
        guard nextPacket < usable else {
            status.pointee = source.complete ? .endOfStream : .noDataNow
            return nil
        }
        let first = Int64(packets[nextPacket].offset)
        if Int64(packets[nextPacket].size) > Int64(input.byteCapacity) {
            input = AVAudioCompressedBuffer(
                format: inputFormat, packetCapacity: Self.inputPackets, maximumPacketSize: Int(packets[nextPacket].size)
            )
        }
        var count = 0
        var span = 0
        while nextPacket + count < usable, count < Int(input.packetCapacity) {
            let entry = packets[nextPacket + count]
            let start = Int64(entry.offset) - first
            let end = start + Int64(entry.size)
            // One read takes the batch, so each packet must lie after the
            // last; a damaged file's may not, and start a batch of their own.
            guard start >= span, first + end <= source.available, end <= Int64(input.byteCapacity) else { break }
            count += 1
            span = Int(end)
        }
        guard count > 0, let descriptions = input.packetDescriptions,
              pread(file.fileDescriptor, input.data, span, off_t(first)) == span else {
            // A complete file has every byte it will have, so a packet past its end is where the sound stops.
            status.pointee = source.complete ? .endOfStream : .noDataNow
            return nil
        }
        for index in 0..<count {
            let entry = packets[nextPacket + index]
            descriptions[index] = AudioStreamPacketDescription(
                mStartOffset: Int64(entry.offset) - first, mVariableFramesInPacket: 0, mDataByteSize: UInt32(entry.size)
            )
        }
        input.packetCount = AVAudioPacketCount(count)
        input.byteLength = UInt32(span)
        nextPacket += count
        status.pointee = .haveData
        return input
    }
}
