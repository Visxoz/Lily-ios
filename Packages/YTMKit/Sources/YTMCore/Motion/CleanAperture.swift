import Foundation

/// Cuts a clip taller than 3:4 to its middle 3:4 with a clean aperture box, as the lock screen plays no other shape:
/// only the header changes, so nothing is decoded or encoded, which iOS refuses in the background.
enum CleanAperture {
    /// The clip as a new file cut to 3:4, or nil where it fits already or isn't a plain MP4 as expected.
    static func tall(_ file: URL) throws -> URL? {
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        guard let moov = boxes(in: data, from: 0, to: data.count)?.first(where: { $0.type == "moov" }),
              let edited = tall(moov: Array(data[moov.start ..< moov.end]), at: moov.start)
        else { return nil }
        let cropped = URL.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        do {
            try Data().write(to: cropped)
            let handle = try FileHandle(forWritingTo: cropped)
            defer { try? handle.close() }
            try handle.write(contentsOf: data[..<moov.start])
            try handle.write(contentsOf: edited)
            try handle.write(contentsOf: data[moov.end...])
        } catch {
            try? FileManager.default.removeItem(at: cropped)
            throw error
        }
        return cropped
    }

    /// `moov`, found `at` that offset in its file, with a `clap` on its first video track's sample entry.
    static func tall(moov: [UInt8], at origin: Int) -> [UInt8]? {
        var bytes = moov
        guard let top = boxes(in: bytes, from: 8, to: bytes.count), u32(bytes, 0) != 1,
              // Fragments place samples by offsets this doesn't move.
              !top.contains(where: { $0.type == "mvex" })
        else { return nil }
        for trak in top where trak.type == "trak" {
            guard let mdia = child("mdia", of: trak, in: bytes), let minf = child("minf", of: mdia, in: bytes),
                  let stbl = child("stbl", of: minf, in: bytes), let stsd = child("stsd", of: stbl, in: bytes),
                  let entry = boxes(in: bytes, from: stsd.start + stsd.header + 8, to: stsd.end)?.first,
                  ["avc1", "avc3", "hvc1", "hev1"].contains(entry.type)
            else { continue }
            guard entry.end - entry.start >= entry.header + 78, let width = u16(bytes, entry.start + entry.header + 24), let height = u16(bytes, entry.start + entry.header + 26),
                  let tkhd = child("tkhd", of: trak, in: bytes), tkhd.start + 8 < bytes.count
            else { return nil }
            let size = tkhd.start + (bytes[tkhd.start + 8] == 0 ? 84 : 96)
            // Only upright (the matrix's a, b, c, d before the size) and square-pixelled, where the shown size is the coded one.
            guard size + 8 <= tkhd.end, [size - 36, size - 32, size - 24, size - 20].compactMap({ u32(bytes, $0) }) == [1 << 16, 0, 0, 1 << 16],
                  u32(bytes, size) == width << 16, u32(bytes, size + 4) == height << 16
            else { return nil }
            // Even, as decoders need.
            let tall = Int((Double(width) * 4 / 3 / 2).rounded()) * 2
            let enclosing = [Box(type: "moov", start: 0, header: 8, end: bytes.count), trak, mdia, minf, stbl, stsd, entry]
            guard height > tall + 1, enclosing.allSatisfy({ $0.header == 8 }),
                  let inside = boxes(in: bytes, from: entry.start + entry.header + 78, to: entry.end),
                  !inside.contains(where: { $0.type == "clap" })
            else { return nil }
            // Centred, as its offsets are from the middle: width/1, height/1, then 0/1 across and down.
            let clap = [40, 0x636C_6170, width, 1, tall, 1, 0, 1, 0, 1].flatMap { value in
                (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
            }
            // The samples after the moov move down with it.
            let moved = origin + entry.end
            for other in top where other.type == "trak" {
                guard shift(other, past: moved, by: clap.count, in: &bytes) else { return nil }
            }
            put32(&bytes, size + 4, tall << 16)
            for box in enclosing { put32(&bytes, box.start, box.end - box.start + clap.count) }
            bytes.insert(contentsOf: clap, at: entry.end)
            return bytes
        }
        return nil
    }

    private struct Box {
        let type: String
        let start: Int
        let header: Int
        let end: Int
    }

    /// The track's chunk offsets at or past `moved`, moved by `delta`; false when its table is malformed.
    private static func shift(_ trak: Box, past moved: Int, by delta: Int, in bytes: inout [UInt8]) -> Bool {
        guard let mdia = child("mdia", of: trak, in: bytes), let minf = child("minf", of: mdia, in: bytes),
              let stbl = child("stbl", of: minf, in: bytes), let table = boxes(in: bytes, from: stbl.start + stbl.header, to: stbl.end)
        else { return false }
        for box in table where box.type == "stco" || box.type == "co64" {
            let width = box.type == "stco" ? 4 : 8
            let first = box.start + box.header + 8
            guard let count = u32(bytes, first - 4), count <= (box.end - first) / width else { return false }
            for at in stride(from: first, to: first + count * width, by: width) {
                guard let offset = width == 4 ? u32(bytes, at) : u64(bytes, at) else { return false }
                guard offset >= moved else { continue }
                let (shifted, overflow) = offset.addingReportingOverflow(delta)
                // A 32-bit table can't hold an offset past 4 GB.
                if overflow || width == 4 && shifted > Int(UInt32.max) { return false }
                if width == 8 { put32(&bytes, at, shifted >> 32) }
                put32(&bytes, at + width - 4, shifted)
            }
        }
        return true
    }

    private static func child(_ type: String, of box: Box, in bytes: [UInt8]) -> Box? {
        boxes(in: bytes, from: box.start + box.header, to: box.end)?.first { $0.type == type }
    }

    /// The boxes from `start` to `end`; nil when one runs past the end.
    private static func boxes<Bytes: RandomAccessCollection<UInt8>>(in bytes: Bytes, from start: Int, to end: Int) -> [Box]?
    where Bytes.Index == Int {
        var found: [Box] = []
        var at = start
        while at + 8 <= end {
            guard var size = u32(bytes, at) else { return nil }
            var header = 8
            if size == 1 {
                guard let large = u64(bytes, at + 8) else { return nil }
                size = large
                header = 16
            } else if size == 0 {
                size = end - at
            }
            guard size >= header, size <= end - at else { return nil }
            found.append(Box(type: String(decoding: bytes[at + 4 ..< at + 8], as: UTF8.self), start: at, header: header, end: at + size))
            at += size
        }
        return found
    }

    private static func u16<Bytes: RandomAccessCollection<UInt8>>(_ bytes: Bytes, _ at: Int) -> Int? where Bytes.Index == Int {
        read(bytes, at, 2)
    }

    private static func u32<Bytes: RandomAccessCollection<UInt8>>(_ bytes: Bytes, _ at: Int) -> Int? where Bytes.Index == Int {
        read(bytes, at, 4)
    }

    /// Nil past `Int.max`, which no real file reaches.
    private static func u64<Bytes: RandomAccessCollection<UInt8>>(_ bytes: Bytes, _ at: Int) -> Int? where Bytes.Index == Int {
        guard let high = read(bytes, at, 4), let low = read(bytes, at + 4, 4), high < 1 << 31 else { return nil }
        return high << 32 | low
    }

    private static func read<Bytes: RandomAccessCollection<UInt8>>(_ bytes: Bytes, _ at: Int, _ count: Int) -> Int?
    where Bytes.Index == Int {
        guard at >= bytes.startIndex, at + count <= bytes.endIndex else { return nil }
        return bytes[at ..< at + count].reduce(0) { $0 << 8 | Int($1) }
    }

    private static func put32(_ bytes: inout [UInt8], _ at: Int, _ value: Int) {
        for index in 0 ..< 4 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
    }
}
