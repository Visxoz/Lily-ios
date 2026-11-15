import AVFoundation
import Testing
@testable import YTMAudio

/// Containers built in code, so the tests need no audio files: a few
/// seconds of a test signal encoded with AudioToolbox, wrapped as YouTube
/// wraps its Opus and AAC.
enum Fixtures {
    static let rate = 48_000.0

    /// A tone that changes pitch every 10 ms and starts after `silence`
    /// frames, so any frame lost, repeated or shifted shows.
    static func signal(frames: Int, silence: Int = 0) -> [Float] {
        (0..<frames).map { frame in
            guard frame >= silence else { return 0 }
            let step = Double(frame / 480 % 7 + 2)
            return Float(0.4 * sin(Double(frame) * step * 0.01))
        }
    }

    // MARK: Opus in WebM

    struct Encoded {
        var packets: [[UInt8]]
        var leadingFrames: Int
        var cookie: Data?
    }

    /// `samples` (mono, duplicated to stereo) encoded with AudioToolbox.
    static func encode(_ samples: [Float], format id: AudioFormatID, rate: Double = rate) throws -> Encoded {
        let pcm = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: id, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: id == kAudioFormatOpus ? 960 : 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        let compressed = try #require(AVAudioFormat(streamDescription: &description))
        let encoder = try #require(AVAudioConverter(from: pcm, to: compressed))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(samples.count)))
        input.frameLength = AVAudioFrameCount(samples.count)
        let channels = try #require(input.floatChannelData)
        for (frame, sample) in samples.enumerated() {
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        var packets: [[UInt8]] = []
        var given = false
        while true {
            let output = AVAudioCompressedBuffer(format: compressed, packetCapacity: 16, maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            let status = encoder.convert(to: output, error: &error) { _, status in
                defer { given = true }
                status.pointee = given ? AVAudioConverterInputStatus.endOfStream : .haveData
                return given ? nil : input
            }
            for index in 0..<Int(output.packetCount) {
                let packet = try #require(output.packetDescriptions?[index])
                packets.append(Array(UnsafeRawBufferPointer(start: output.data + Int(packet.mStartOffset), count: Int(packet.mDataByteSize))))
            }
            if status != .haveData || output.packetCount == 0 {
                break
            }
        }
        return Encoded(packets: packets, leadingFrames: Int(encoder.primeInfo.leadingFrames), cookie: encoder.magicCookie)
    }

    /// The signal as Opus in WebM, its length set by DiscardPadding on the
    /// last block. `chunked` writes a Segment and Clusters of unknown size, as a live encoder does.
    static func opusWebM(_ samples: [Float], chunked: Bool = false) throws -> Data {
        let encoded = try encode(samples, format: kAudioFormatOpus)
        let padding = encoded.packets.count * 960 - encoded.leadingFrames - samples.count
        var head = Array("OpusHead".utf8) + [1, 2]
        head += [UInt8(encoded.leadingFrames & 0xFF), UInt8(encoded.leadingFrames >> 8), 0x80, 0xBB, 0, 0, 0, 0, 0]
        var clusters: [UInt8] = []
        for (index, packet) in encoded.packets.enumerated() {
            let block = EBMLWriter.block(timecode: index * 20, packets: [packet])
            if index == encoded.packets.count - 1 {
                let nanoseconds = UInt64(Double(padding) / rate * 1e9)
                clusters += EBMLWriter.element(EBML.blockGroup, EBMLWriter.uint(EBML.discardPadding, nanoseconds) + EBMLWriter.element(EBML.block, block))
            } else {
                clusters += EBMLWriter.element(EBML.simpleBlock, block)
            }
        }
        let info = EBMLWriter.element(EBML.info, EBMLWriter.uint(EBML.timecodeScale, 1_000_000)
            + EBMLWriter.float(EBML.duration, Double(samples.count) / rate * 1_000))
        let entry = EBMLWriter.uint(EBML.trackNumber, 1) + EBMLWriter.element(EBML.codecID, Array("A_OPUS".utf8))
            + EBMLWriter.element(EBML.codecPrivate, head)
        let tracks = EBMLWriter.element(EBML.tracks, EBMLWriter.element(EBML.trackEntry, entry))
        let cluster = EBMLWriter.uint(0xE7, 0) + clusters
        let segment = info + tracks + (chunked ? EBMLWriter.unknown(EBML.cluster) + cluster : EBMLWriter.element(EBML.cluster, cluster))
        let header = EBMLWriter.element(0x1A45_DFA3, EBMLWriter.element(0x4282, Array("webm".utf8)))
        return Data(header + (chunked ? EBMLWriter.unknown(EBML.segment) + segment : EBMLWriter.element(EBML.segment, segment)))
    }

    // MARK: AAC in fragmented MP4

    /// The signal as AAC in fragmented MP4, two fragments. YouTube's DASH
    /// files have no edit list; with `edited`, one gives the priming and
    /// length, or starts at `editStart` in place of the priming.
    static func aacMP4(_ samples: [Float], rate: Double = 44_100, edited: Bool = false, editStart: UInt64? = nil) throws -> Data {
        let encoded = try encode(samples, format: kAudioFormatMPEG4AAC, rate: rate)
        let cookie = try #require(encoded.cookie)
        let scale = UInt32(rate)
        let entry = MP4Writer.box("mp4a", [UInt8](repeating: 0, count: 6) + MP4Writer.u16(1) + [UInt8](repeating: 0, count: 8)
            + MP4Writer.u16(2) + MP4Writer.u16(16) + [0, 0, 0, 0] + MP4Writer.u32(scale << 16)
            + MP4Writer.box("esds", [0, 0, 0, 0] + Array(cookie)))
        let table = MP4Writer.box("stbl", MP4Writer.box("stsd", [0, 0, 0, 0] + MP4Writer.u32(1) + entry))
        let media = MP4Writer.box("mdia", MP4Writer.box("mdhd", [0, 0, 0, 0] + MP4Writer.u32(0) + MP4Writer.u32(0) + MP4Writer.u32(scale)
                + MP4Writer.u32(UInt32(encoded.packets.count * 1_024)) + [0, 0, 0, 0])
            + MP4Writer.box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
            + MP4Writer.box("minf", table))
        let edits = MP4Writer.box("edts", MP4Writer.box("elst", [1, 0, 0, 0] + MP4Writer.u32(1) + MP4Writer.u64(UInt64(samples.count))
            + MP4Writer.u64(editStart ?? UInt64(encoded.leadingFrames)) + MP4Writer.u16(1) + MP4Writer.u16(0)))
        let track = MP4Writer.box("trak", MP4Writer.box("tkhd", [0, 0, 0, 3] + MP4Writer.u32(0) + MP4Writer.u32(0) + MP4Writer.u32(1)
            + [UInt8](repeating: 0, count: 64)) + (edited ? edits : []) + media)
        let movie = MP4Writer.box("moov", MP4Writer.box("mvhd", [0, 0, 0, 0] + MP4Writer.u32(0) + MP4Writer.u32(0) + MP4Writer.u32(scale)
            + [UInt8](repeating: 0, count: 84)) + MP4Writer.box("mvex", MP4Writer.box("trex", [0, 0, 0, 0] + MP4Writer.u32(1)
            + MP4Writer.u32(1) + MP4Writer.u32(1_024) + MP4Writer.u32(0) + MP4Writer.u32(0))) + track)
        var file = MP4Writer.box("ftyp", Array("dash".utf8) + [0, 0, 0, 0] + Array("iso6mp41".utf8)) + movie
        let half = encoded.packets.count / 2
        for packets in [encoded.packets[..<half], encoded.packets[half...]] {
            file += MP4Writer.fragment(Array(packets))
        }
        return Data(file)
    }
}

enum EBMLWriter {
    static func element(_ id: UInt32, _ body: [UInt8]) -> [UInt8] {
        idBytes(id) + [0x01] + (0..<7).map { UInt8(truncatingIfNeeded: UInt64(body.count) >> (8 * (6 - $0))) } + body
    }

    /// An element whose size is unknown, so its children simply follow.
    static func unknown(_ id: UInt32) -> [UInt8] {
        idBytes(id) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    }

    static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        element(id, (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) })
    }

    static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
        uint(id, value.bitPattern)
    }

    /// A block of track 1, its packets Xiph-laced when there are several.
    static func block(timecode: Int, packets: [[UInt8]]) -> [UInt8] {
        let header: [UInt8] = [0x81, UInt8(timecode >> 8 & 0xFF), UInt8(timecode & 0xFF)]
        guard packets.count > 1 else { return header + [0x80] + packets[0] }
        var lacing: [UInt8] = [UInt8(packets.count - 1)]
        for packet in packets.dropLast() {
            lacing += [UInt8](repeating: 255, count: packet.count / 255) + [UInt8(packet.count % 255)]
        }
        return header + [0x82] + lacing + packets.flatMap { $0 }
    }

    private static func idBytes(_ id: UInt32) -> [UInt8] {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: id >> (8 * (3 - $0))) }
        return Array(bytes.drop { $0 == 0 })
    }
}

enum MP4Writer {
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        u32(UInt32(body.count + 8)) + Array(type.utf8) + body
    }

    static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * (3 - $0))) }
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        u32(UInt32(value >> 32)) + u32(UInt32(truncatingIfNeeded: value))
    }

    static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// A movie fragment and its media data, sizes listed in the track run,
    /// its data offset counted from the fragment's start as YouTube's are.
    static func fragment(_ packets: [[UInt8]]) -> [UInt8] {
        func fragmentBox(dataOffset: UInt32) -> [UInt8] {
            let header = box("tfhd", [0x00, 0x02, 0x00, 0x08] + u32(1) + u32(1_024))
            let run = box("trun", [0, 0, 0x02, 0x01] + u32(UInt32(packets.count)) + u32(dataOffset) + packets.flatMap { u32(UInt32($0.count)) })
            return box("moof", box("mfhd", [0, 0, 0, 0] + u32(1)) + box("traf", header + run))
        }
        let length = UInt32(fragmentBox(dataOffset: 0).count)
        return fragmentBox(dataOffset: length + 8) + box("mdat", packets.flatMap { $0 })
    }
}

/// Serves a file held in memory, in pieces, as the network would; refuses
/// ranges from `refuseFrom` on at any URL not marked fresh.
struct MemoryByteSource: ByteSource {
    let files: [String: Data]
    var piece = 4_096
    var refuseFrom: Int64?

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        let file = files.first { url.absoluteString.contains($0.key) }?.value ?? Data()
        let refused = refuseFrom.map { range.lowerBound >= $0 && !url.absoluteString.contains("fresh") } ?? false
        return AsyncThrowingStream { continuation in
            guard !refused else {
                continuation.finish(throwing: ByteSourceError.refused)
                return
            }
            var offset = Int(range.lowerBound)
            let end = Int(min(range.upperBound, Int64(file.count)))
            while offset < end {
                let next = min(offset + piece, end)
                continuation.yield(file.subdata(in: offset..<next))
                offset = next
            }
            continuation.finish()
        }
    }
}

extension AudioItem {
    /// An item served by `MemoryByteSource` under `name`, as googlevideo names its files.
    static func fixture(_ name: String, length: Int, id: String? = nil, loudnessDB: Float = 0) throws -> AudioItem {
        let query = "itag=251&clen=\(length)&lmt=1&file=\(name)"
        let url = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?\(query)"))
        let fresh = try #require(URL(string: "https://rr2.googlevideo.com/videoplayback?\(query)&n=fresh"))
        return AudioItem(
            id: id ?? name,
            url: url,
            headers: [:],
            contentLength: Int64(length),
            cacheKey: "\(name)-\(UUID().uuidString)",
            loudnessDB: loudnessDB,
            refresh: { (url: fresh, headers: [:]) }
        )
    }
}
