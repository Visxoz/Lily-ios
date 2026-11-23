import Foundation

/// Line-synced LRC. Enhanced `<mm:ss.xx>` word stamps are dropped, so lines carry no words.
enum LRC {
    static func lyrics(_ text: String, source: String) -> Lyrics? {
        var timed: [(start: Double, line: String)] = []
        var offset = 0.0
        let body = text.first == "\u{FEFF}" ? text.dropFirst() : text[...]
        for line in body.split(whereSeparator: \.isNewline) {
            var rest = line
            var starts: [Double] = []
            // `[00:12.00][01:30.00]chorus` is one line sung at each stamp.
            while rest.first == "[", let close = rest.firstIndex(of: "]"), let start = seconds(rest.dropFirst()[..<close]) {
                starts.append(start)
                rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
            }
            guard !starts.isEmpty else {
                // Milliseconds; a positive offset shows the lines sooner.
                if line.hasPrefix("[offset:"),
                   let ms = Int(line.dropFirst(8).prefix(while: { $0 != "]" }).trimmingCharacters(in: .whitespaces)) {
                    offset = Double(ms) / 1000
                }
                continue
            }
            let words = unstamped(rest)
            // A bare stamp is a pause, which YouTube Music shows as a note.
            let shown = words.isEmpty ? "♪" : words
            timed += starts.map { (start: $0, line: shown) }
        }
        guard !timed.isEmpty else { return nil }
        // Stable (SE-0372), so lines sharing a start keep the file's order.
        timed.sort { $0.start < $1.start }
        return Lyrics(lines: timed.map { $0.line }, starts: timed.map { max(0, $0.start - offset) }, source: source)
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx` or `mm:ss:xx`. Read as one decimal so `13.13` equals the literal;
    /// the three-digit cap rules out overflow.
    private static func seconds(_ stamp: Substring) -> Double? {
        let parts = stamp.split(omittingEmptySubsequences: false) { $0 == ":" || $0 == "." }
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ part in (1...3).contains(part.count) && part.allSatisfy { "0123456789".contains($0) } }),
              let minutes = Int(parts[0]), let whole = Int(parts[1])
        else { return nil }
        return Double("\(minutes * 60 + whole).\(parts.count == 3 ? parts[2] : "0")")
    }

    private static func unstamped(_ body: Substring) -> String {
        var text = ""
        var rest = body
        while let open = rest.firstIndex(of: "<") {
            let after = rest.index(after: open)
            // A stamp is at most 11 characters, so a stray `<` never scans the rest of the line.
            if let close = rest[after...].prefix(12).firstIndex(of: ">"), seconds(rest[after..<close]) != nil {
                text += rest[..<open]
                rest = rest[rest.index(after: close)...]
                // `Alpha <00:01.40> beta` keeps one space between the words.
                if text.last?.isWhitespace ?? true { rest = rest.drop(while: \.isWhitespace) }
            } else {
                text += rest[..<after]
                rest = rest[after...]
            }
        }
        return (text + rest).trimmingCharacters(in: .whitespaces)
    }
}
