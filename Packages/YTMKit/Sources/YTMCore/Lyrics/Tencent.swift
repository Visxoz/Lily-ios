import Foundation

/// Tencent Music's word-timed lyrics: KuGou's KRC and QQ Music's QRC, lines of `[startMs,lengthMs]` and their words.
enum Tencent {
    /// `[lineMs,lengthMs]<offsetMs,lengthMs,0>word…`, each word timed from its line's start.
    static func krc(_ text: String, source: String) -> Lyrics? {
        lyrics(text, source: source) { body, lineMs in
            var words: [Lyrics.Word] = []
            var rest = body
            while rest.first == "<", let close = rest.firstIndex(of: ">") {
                let timing = rest.dropFirst()[..<close].split(separator: ",")
                let next = rest[rest.index(after: close)...]
                let end = next.firstIndex(of: "<") ?? next.endIndex
                if timing.count == 3, let at = Int(timing[0]), let length = Int(timing[1]) {
                    append(next[..<end], start: lineMs + Double(at), length: Double(length), to: &words)
                }
                rest = next[end...]
            }
            return words
        }
    }

    /// `[lineMs,lengthMs]word(startMs,lengthMs)…`, each word timed from the song's start.
    static func qrc(_ text: String, source: String) -> Lyrics? {
        // Built once, as a regex literal is parsed and compiled afresh each time it's evaluated.
        let stampPattern = #/\((\d+),(\d+)\)/#
        return lyrics(text, source: source) { body, _ in
            var words: [Lyrics.Word] = []
            var rest = body
            // A word's text runs to its stamp; brackets that aren't a stamp, as in "(oh)", are words' own.
            while let stamp = rest.firstMatch(of: stampPattern) {
                if let start = Int(stamp.1), let length = Int(stamp.2) {
                    append(rest[..<stamp.range.lowerBound], start: Double(start), length: Double(length), to: &words)
                }
                rest = rest[stamp.range.upperBound...]
            }
            return words
        }
    }

    /// QQ Music's QRC document, its lyrics in the `LyricContent` attribute, read by hand: an XML parser would join
    /// the attribute's lines into one.
    static func qrcContent(_ xml: String) -> String? {
        guard let open = xml.range(of: "LyricContent=\""), let close = xml[open.upperBound...].firstIndex(of: "\"") else { return nil }
        return unescaped(xml[open.upperBound..<close])
    }

    /// The text of a KRC download's base64 `content`, nil unless it unmasks to a zlib stream.
    static func krcText(_ content: String) -> String? {
        guard let data = Data(base64Encoded: content), data.starts(with: "krc1".utf8) else { return nil }
        var bytes = [UInt8](data.dropFirst(4))
        for i in bytes.indices { bytes[i] ^= krcKey[i & 15] }
        // Apple's zlib is raw DEFLATE, so the stream's two-byte header goes; its checksum after is ignored.
        guard bytes.count > 2, bytes[0] == 0x78,
              let inflated = try? (Data(bytes.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data
        else { return nil }
        return String(decoding: inflated, as: UTF8.self)
    }

    /// The mask every KuGou client shares.
    private static let krcKey: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]

    private struct Row {
        var start: Double
        var length: Double
        var words: [Lyrics.Word]
    }

    /// The lines with timed words, less the "title - artist" line and credits both sites open with. Those are laid
    /// end to end from the start, each given the same made-up length, which sung lines never are.
    private static func lyrics(_ text: String, source: String, words: (Substring, _ lineMs: Double) -> [Lyrics.Word]) -> Lyrics? {
        var rows: [Row] = []
        var offset = 0.0
        let body = text.first == "\u{FEFF}" ? text.dropFirst() : text[...]
        for line in body.split(whereSeparator: \.isNewline) {
            // Times are whole milliseconds, read as integers so "inf", "nan" or hex can't get through.
            if line.hasPrefix("[offset:"), let ms = Int(line.dropFirst(8).prefix { $0 != "]" }) {
                // A positive offset shows the lines sooner, as in LRC.
                offset = Double(ms)
                continue
            }
            guard line.first == "[", let close = line.firstIndex(of: "]") else { continue }
            let stamp = line.dropFirst()[..<close].split(separator: ",")
            guard stamp.count == 2, let startMs = Int(stamp[0]), let lengthMs = Int(stamp[1]) else { continue }
            let start = Double(startMs)
            var found = words(line[line.index(after: close)...], start)
            guard let first = found.indices.first, let last = found.indices.last else { continue }
            found[first].text = String(found[first].text.drop(while: \.isWhitespace))
            while found[last].text.last?.isWhitespace == true { found[last].text.removeLast() }
            rows.append(Row(start: start, length: Double(lengthMs), words: found))
        }
        if let first = rows.first, first.start < 1000, first.words.map(\.text).joined().contains(" - ") {
            var end = 1
            while end < rows.count, abs(rows[end].start - rows[end - 1].start - rows[end - 1].length) <= 20,
                  abs(rows[end].length - first.length) <= 20 {
                end += 1
            }
            rows.removeFirst(end)
        }
        guard !rows.isEmpty else { return nil }
        let seconds = { (ms: Double) in max(0, ms - offset) / 1000 }
        return Lyrics(
            lines: rows.map { $0.words.map(\.text).joined() },
            starts: rows.map { seconds($0.start) },
            words: rows.map { $0.words.map { Lyrics.Word(text: $0.text, start: seconds($0.start), end: seconds($0.end)) } },
            source: source
        )
    }

    /// A space timed alone joins the word before, as a line's text is its words joined; times are in milliseconds
    /// until `lyrics` makes them seconds.
    private static func append(_ text: Substring, start: Double, length: Double, to words: inout [Lyrics.Word]) {
        let text = unescaped(text)
        if text.allSatisfy(\.isWhitespace) {
            if let last = words.indices.last { words[last].text += text }
        } else {
            words.append(Lyrics.Word(text: text, start: start, end: start + length))
        }
    }

    private static func unescaped(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        return text.replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
