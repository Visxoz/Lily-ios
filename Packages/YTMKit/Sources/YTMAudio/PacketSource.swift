import AudioToolbox
import Foundation

/// A container read as its bytes arrive, which finds the codec and lists
/// where each packet lies in the file, so packets are read from the cache
/// file when decoded rather than held in memory.
protocol PacketSource: AnyObject {
    /// The codec, once the container's header has been read.
    var format: SourceFormat? { get }
    var packets: PacketIndex { get }
    /// Codec frames of padding after the music, known once the last packet is read.
    var trailingFrames: Int64 { get }
    /// Reads the next bytes of the file; every byte comes once, in order.
    func parse(_ bytes: UnsafeRawBufferPointer) throws
}

/// What the decoder opens a source with.
struct SourceFormat {
    var description: AudioStreamBasicDescription
    var cookie: Data?
    /// Codec frames before the music: Opus's pre-skip or AAC's priming.
    var leadingFrames: Int64
    /// The container's stated length in seconds, until the true one is known.
    var duration: Double?

    /// No file plays longer than this; one that says so is damaged.
    static let longestSeconds = 24 * 60 * 60.0

    var sampleRate: Double { description.mSampleRate }
    var isOpus: Bool { description.mFormatID == kAudioFormatOpus }
}

/// Where each packet lies and how many frames it decodes to, in eight bytes
/// a packet, so even an hour's mix indexes in under two megabytes.
struct PacketIndex {
    struct Entry {
        let offset: UInt32
        let size: UInt16
        let frames: UInt16
    }

    /// A day of 20 ms packets. A container can list packets in a few bytes
    /// each, so a damaged one could otherwise fill memory with them.
    static let capacity = Int(SourceFormat.longestSeconds) * 50

    private(set) var entries: ContiguousArray<Entry> = []
    /// Codec frames in every packet listed.
    private(set) var frames: Int64 = 0

    var count: Int { entries.count }
    subscript(index: Int) -> Entry { entries[index] }

    mutating func append(offset: Int64, size: Int, frames: Int) throws {
        guard entries.count < Self.capacity else { throw AudioFailure.damaged }
        guard let offset = UInt32(exactly: offset), let size = UInt16(exactly: size), size > 0,
              let frames = UInt16(exactly: frames) else { throw AudioFailure.unsupported }
        entries.append(Entry(offset: offset, size: size, frames: frames))
        self.frames += Int64(frames)
    }

    /// The packet holding codec frame `frame`, and the frame it starts on;
    /// nil past the packets listed so far.
    func packet(holding frame: Int64) -> (index: Int, start: Int64)? {
        var start: Int64 = 0
        for (index, entry) in entries.enumerated() {
            let end = start + Int64(entry.frames)
            if frame < end {
                return (index, start)
            }
            start = end
        }
        return nil
    }

    /// The codec frame packet `index` starts on.
    func start(of index: Int) -> Int64 {
        entries.prefix(index).reduce(0) { $0 + Int64($1.frames) }
    }
}

enum PacketSources {
    /// Bytes enough to tell the containers apart.
    static let sniffLength = 8

    /// A source for the container the file's first bytes announce.
    static func make(sniffing head: UnsafeRawBufferPointer) throws(AudioFailure) -> any PacketSource {
        guard head.count >= sniffLength else { throw .damaged }
        if head.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) {
            return WebMDemuxer()
        }
        let box = head[4..<8]
        if box.elementsEqual("ftyp".utf8) || box.elementsEqual("styp".utf8) || box.elementsEqual("moov".utf8) {
            return MP4Demuxer()
        }
        throw .unsupported
    }
}
